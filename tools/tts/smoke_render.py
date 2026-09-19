"""Prove IndexTTS-2.5 loads and renders on the 3090 Ti, beside a training run.

The point is not audio quality yet -- it is that the riskiest assumption in the
plan holds: that a 6 GB TTS model can share a 24 GB card with a LoRA trainer
that is already resident, on Windows, without either one falling over.

Two guards, in this order, before anything is loaded:

1. The VRAM gate. Free memory comes from nvidia-smi, never from
   ``torch.cuda.mem_get_info`` -- under Windows WDDM the latter reported the
   whole 24 GB card free while the trainer held 17.4 GB of it.
2. The memory fence, so that if this process is wrong about how much room it
   has, the allocation that fails is ITS OWN. The trainer has hours invested;
   this has seconds.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def free_vram_mb() -> int | None:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--id=0", "--query-gpu=memory.free",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        return int(out.stdout.strip().splitlines()[0])
    except (ValueError, IndexError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", default=r"D:\models\IndexTTS-2.5")
    ap.add_argument("--voices", default=r"D:\models\voicepack-v1")
    ap.add_argument("--out", default=r"D:\models\tts-smoke")
    ap.add_argument("--claim-mb", type=int, default=8192)
    ap.add_argument("--fraction", type=float, default=0.30)
    ap.add_argument(
        "--text",
        default="If only our responsibilities were proportional to our size, "
                "then I could leave all this to you, couldn't I?",
    )
    args = ap.parse_args()

    free = free_vram_mb()
    print(f"free VRAM (nvidia-smi): {free} MiB")
    if free is None or free < args.claim_mb:
        print(f"REFUSING: need {args.claim_mb} MiB free, the gate is shut")
        return 2

    import torch
    print(f"torch {torch.__version__} cuda={torch.cuda.is_available()}")
    # Deliberately printed next to the real number: this is the value that
    # cannot be trusted on Windows, and seeing both makes that concrete.
    if torch.cuda.is_available():
        print(f"torch thinks free: {torch.cuda.mem_get_info()[0] / 2**20:.0f} MiB "
              f"(nvidia-smi says {free} MiB)")
        torch.cuda.set_per_process_memory_fraction(args.fraction, 0)
        print(f"memory fence: {args.fraction:.0%} of the card")

    from indextts.infer_v2_5 import IndexTTS2

    model_dir = Path(args.model_dir)
    started = time.time()
    tts = IndexTTS2(
        cfg_path=str(model_dir / "config.yaml"),
        model_dir=str(model_dir),
        use_bf16=True,
        device="cuda:0",
        use_cuda_kernel=False,
    )
    print(f"model loaded in {time.time() - started:.1f}s")

    manifest = json.loads((Path(args.voices) / "manifest.json").read_text())
    # One of each, because the whole feature is that men and women sound
    # different.
    picks = []
    for gender in ("male", "female"):
        for clip in manifest["clips"]:
            if clip["gender"] == gender:
                picks.append(clip)
                break

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for clip in picks:
        target = out_dir / f"smoke-{clip['gender']}-{clip['voice_id']}.wav"
        started = time.time()
        tts.infer(
            spk_audio_prompt=str(Path(args.voices) / clip["file"]),
            text=args.text,
            output_path=str(target),
            lang="en",
            verbose=False,
        )
        elapsed = time.time() - started
        size = target.stat().st_size if target.exists() else 0
        results.append((clip["gender"], clip["voice_id"], elapsed, size))
        print(f"rendered {clip['gender']:>6} {clip['voice_id']:<18} "
              f"{elapsed:6.1f}s  {size/1024:8.1f} KiB  -> {target.name}")

    if torch.cuda.is_available():
        print(f"peak allocated: {torch.cuda.max_memory_allocated() / 2**30:.2f} GB")
    print(f"free VRAM after: {free_vram_mb()} MiB")

    ok = all(size > 1024 for _, _, _, size in results)
    print("SMOKE_OK" if ok else "SMOKE_FAILED: an output was empty")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
