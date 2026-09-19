"""Decide when a TTS render may use the GPU, without ever starving the trainer.

The 3090 Ti is not idle and is not going to become idle: a Neiro training run
holds it at 100% utilisation indefinitely, by design. So "render only when the
GPU is idle" renders *nothing, forever*. The gate is FREE MEMORY instead, which
is the resource actually being contended and which self-adjusts when the
training job ends, restarts, or comes back bigger.

**Free memory is read from nvidia-smi, never from torch.** Measured on the
Windows box on 2026-09-19 while the trainer held 17.4 GB:
``torch.cuda.mem_get_info()`` reported **24.45 GB free** -- essentially the
whole card -- because Windows WDDM virtualizes VRAM and overcommits it into
system RAM, so the CUDA runtime does not see another process's resident
allocation. nvidia-smi reported the true 6,876 MiB. A gate built on
``mem_get_info`` would therefore pass every single time and OOM against the
trainer, which is precisely the thing it exists to prevent.

Hysteresis, not a single threshold: claiming and releasing at the same number
means a worker that flickers on and off around the boundary, thrashing a card
that something else is trying to use.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

#: Start a new render only with this much free. IndexTTS-2.5 wants ~6 GB and a
#: render allocates more as it runs, so the margin is the point.
CLAIM_MB = 8192

#: Keep going above this, but start nothing new. The band between RELEASE and
#: CLAIM is the hysteresis that stops a worker flickering on the boundary.
RELEASE_MB = 6656  # 6.5 GB

#: Never take more than this share of the card, so that if anything OOMs it is
#: the render worker and never the training run, which has hours invested.
MEMORY_FRACTION = 0.30

#: Touch this file to take the card back by hand, without killing anything.
PAUSE_FILENAME = "TTS_PAUSE"

CLAIM = "claim"
HOLD = "hold"
RELEASE = "release"


def free_vram_mb(device: int = 0, *, runner=None) -> int | None:
    """Free VRAM in MiB, or None if it cannot be determined.

    None means "do not know", and every caller must treat that as "do not
    claim". Guessing here is how a render worker lands on a card that is
    already full.
    """
    exe = shutil.which("nvidia-smi")
    if exe is None and runner is None:
        return None
    run = runner or (
        lambda: subprocess.run(
            [
                exe or "nvidia-smi",
                f"--id={device}",
                "--query-gpu=memory.free",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    )
    try:
        result = run()
    except (OSError, subprocess.SubprocessError) as exc:
        logger.warning("could not read free VRAM: %s", exc)
        return None
    if getattr(result, "returncode", 1) != 0:
        return None
    line = (result.stdout or "").strip().splitlines()
    if not line:
        return None
    try:
        return int(line[0].strip().split()[0])
    except (ValueError, IndexError):
        return None


@dataclass(frozen=True)
class GateDecision:
    action: str
    free_mb: int | None
    reason: str

    @property
    def may_start(self) -> bool:
        return self.action == CLAIM

    @property
    def may_continue(self) -> bool:
        return self.action in (CLAIM, HOLD)


def decide(
    *,
    free_mb: int | None,
    paused: bool = False,
    claim_mb: int = CLAIM_MB,
    release_mb: int = RELEASE_MB,
) -> GateDecision:
    """What a render worker should do right now.

    Pure, so the policy can be tested without a GPU.
    """
    if paused:
        return GateDecision(RELEASE, free_mb, "paused by hand")
    if free_mb is None:
        # Unknown is not permission. A card we cannot measure is a card we do
        # not take.
        return GateDecision(RELEASE, None, "free VRAM unknown")
    if free_mb >= claim_mb:
        return GateDecision(CLAIM, free_mb, f"{free_mb}MiB free")
    if free_mb >= release_mb:
        return GateDecision(
            HOLD, free_mb, f"{free_mb}MiB free: finish current work, start nothing"
        )
    return GateDecision(RELEASE, free_mb, f"only {free_mb}MiB free")


def is_paused(directory: str | Path) -> bool:
    return (Path(directory) / PAUSE_FILENAME).exists()


def apply_memory_fence(torch_module, fraction: float = MEMORY_FRACTION) -> bool:
    """Cap this process's share of the card.

    So that when memory does run out, the allocation that fails is the render
    worker's -- which loses seconds -- rather than the trainer's, which loses
    hours. Returns whether the fence was actually applied.
    """
    try:
        if not torch_module.cuda.is_available():
            return False
        torch_module.cuda.set_per_process_memory_fraction(fraction, 0)
        return True
    except Exception as exc:  # noqa: BLE001 - a missing fence must not be fatal
        logger.warning("could not set per-process memory fraction: %s", exc)
        return False


def gate(directory: str | Path = ".", device: int = 0) -> GateDecision:
    """Read the card and decide, in one call."""
    return decide(
        free_mb=free_vram_mb(device),
        paused=is_paused(os.fspath(directory)),
    )
