"""When a TTS render may take the GPU.

The card is never idle: a training run holds it at 100% utilisation
indefinitely by design, so a gate on UTILISATION renders nothing, ever. The
gate is free memory, and the decision has to be safe in both directions --
starving the trainer costs hours, waiting costs seconds.
"""

from __future__ import annotations

import subprocess
from types import SimpleNamespace

from services.gpu_gate import (
    CLAIM,
    CLAIM_MB,
    HOLD,
    RELEASE,
    RELEASE_MB,
    decide,
    free_vram_mb,
    is_paused,
    apply_memory_fence,
)


def _smi(stdout, returncode=0):
    return lambda: SimpleNamespace(stdout=stdout, returncode=returncode)


class TestReadingTheCard:
    def test_it_parses_nvidia_smi(self):
        assert free_vram_mb(runner=_smi("6876\n")) == 6876

    def test_it_reads_the_first_gpu_line_only(self):
        assert free_vram_mb(runner=_smi("6876\n24000\n")) == 6876

    def test_a_failed_call_is_unknown_not_zero(self):
        # Zero would read as "card full"; unknown is the honest answer and is
        # handled separately below.
        assert free_vram_mb(runner=_smi("", returncode=9)) is None

    def test_garbage_output_is_unknown(self):
        assert free_vram_mb(runner=_smi("N/A\n")) is None

    def test_an_exploding_nvidia_smi_is_unknown(self):
        def boom():
            raise subprocess.TimeoutExpired("nvidia-smi", 15)

        assert free_vram_mb(runner=boom) is None


class TestPolicy:
    def test_an_empty_card_is_claimed(self):
        assert decide(free_mb=24000).action == CLAIM

    def test_the_claim_threshold_is_inclusive(self):
        assert decide(free_mb=CLAIM_MB).action == CLAIM

    def test_the_real_contended_state_starts_nothing(self):
        # Measured on the box with the trainer resident: 6,876 MiB free. The
        # worker must NOT start here, which is why the trainer's batch has to
        # shrink before a render can ever run alongside it.
        decision = decide(free_mb=6876)

        assert decision.action == HOLD
        assert decision.may_start is False
        assert decision.may_continue is True

    def test_a_full_card_releases(self):
        decision = decide(free_mb=RELEASE_MB - 1)

        assert decision.action == RELEASE
        assert decision.may_continue is False

    def test_claim_and_release_are_not_the_same_number(self):
        # One threshold means a worker that flickers on and off around the
        # boundary, thrashing a card something else is using.
        assert RELEASE_MB < CLAIM_MB

    def test_unknown_free_memory_is_never_permission(self):
        # This is the WDDM lesson: torch reported the whole card free while the
        # trainer held 17.4 GB. A gate that treats "cannot tell" as "go ahead"
        # is the failure it exists to prevent.
        decision = decide(free_mb=None)

        assert decision.action == RELEASE
        assert decision.may_start is False

    def test_a_hand_pause_beats_an_empty_card(self):
        assert decide(free_mb=24000, paused=True).action == RELEASE


class TestPauseFile:
    def test_absent_by_default(self, tmp_path):
        assert is_paused(tmp_path) is False

    def test_present_when_touched(self, tmp_path):
        (tmp_path / "TTS_PAUSE").touch()

        assert is_paused(tmp_path) is True


class TestMemoryFence:
    def test_the_fence_is_applied_when_cuda_is_there(self):
        calls = []
        fake = SimpleNamespace(cuda=SimpleNamespace(
            is_available=lambda: True,
            set_per_process_memory_fraction=lambda f, d: calls.append((f, d)),
        ))

        assert apply_memory_fence(fake, 0.3) is True
        assert calls == [(0.3, 0)]

    def test_no_cuda_means_no_fence_and_no_crash(self):
        fake = SimpleNamespace(cuda=SimpleNamespace(is_available=lambda: False))

        assert apply_memory_fence(fake) is False

    def test_a_torch_that_refuses_does_not_take_the_worker_down(self):
        def raiser(f, d):
            raise RuntimeError("unsupported")

        fake = SimpleNamespace(cuda=SimpleNamespace(
            is_available=lambda: True, set_per_process_memory_fraction=raiser,
        ))

        # Losing the fence is worse protection, not a reason to refuse to run.
        assert apply_memory_fence(fake) is False
