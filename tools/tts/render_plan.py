"""Render a chapter plan to audio, one sentence at a time.

The plan decides everything — what to say, in whose voice, in what order — so
this does no thinking. It renders, measures, and concatenates.

**One segment per call, and that is the point.** Rendering a sentence at a time
means each segment's duration IS ``len(samples) / sample_rate``, so the timing
map falls out of the render for free: no forced aligner, no second model, no
drift between the audio and the text. The batch of one is not a limitation
being worked around; it is what buys follow-along.

Model load is a one-off, so this is long-lived by design and renders a whole
chapter per process. At the measured RTF of ~1.8 under contention, starting a
process per chapter would spend more time loading than speaking.
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
        return int(out.stdout.strip().splitlines()[0]) if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--voices", default=r"D:\models\voicepack-v1-full")
    ap.add_argument("--model-dir", default=r"D:\models\IndexTTS-2.5")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0, help="render only the first N segments")
    ap.add_argument("--claim-mb", type=int, default=8192)
    ap.add_argument("--fraction", type=float, default=0.45)
    args = ap.parse_args()

    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    segments = plan["segments"][: args.limit] if args.limit else plan["segments"]

    free = free_vram_mb()
    print(f"free VRAM (nvidia-smi): {free} MiB", flush=True)
    if free is None or free < args.claim_mb:
        print(f"REFUSING: need {args.claim_mb} MiB free; the gate is shut")
        return 2

    import torch
    if torch.cuda.is_available():
        # So that if this process is wrong about how much room it has, the
        # allocation that fails is its own.
        torch.cuda.set_per_process_memory_fraction(args.fraction, 0)

    from indextts.infer_v2_5 import IndexTTS2

    model_dir = Path(args.model_dir)
    started = time.time()
    tts = IndexTTS2(
        cfg_path=str(model_dir / "config.yaml"), model_dir=str(model_dir),
        use_bf16=True, device="cuda:0", use_cuda_kernel=False,
    )
    print(f"model loaded in {time.time() - started:.0f}s", flush=True)

    out_dir = Path(args.out)
    parts_dir = out_dir / "parts"
    parts_dir.mkdir(parents=True, exist_ok=True)
    voice_files = plan["voice_files"]

    timing = []
    cursor_ms = 0.0
    wall = time.time()
    import soundfile as sf

    for index, seg in enumerate(segments):
        target = parts_dir / f"{index:04d}.wav"
        prompt = Path(args.voices) / voice_files[seg["voice"]]
        t = time.time()
        tts.infer(
            spk_audio_prompt=str(prompt), text=seg["text"],
            output_path=str(target), lang="en", verbose=False,
        )
        # The duration IS the measurement. Nothing estimates it.
        data, rate = sf.read(target)
        seconds = len(data) / rate
        timing.append({
            "i": seg["i"], "start_ms": round(cursor_ms),
            "end_ms": round(cursor_ms + seconds * 1000),
            "p": seg["p"], "s": seg["s"], "e": seg["e"],
            "voice": seg["voice"], "speaker": seg.get("speaker"),
            "speech": seg["speech"],
        })
        cursor_ms += seconds * 1000
        if index % 10 == 0 or index == len(segments) - 1:
            done = index + 1
            rate_s = (time.time() - wall) / done
            print(f"  {done}/{len(segments)}  {cursor_ms/1000:6.1f}s audio  "
                  f"{time.time()-t:4.1f}s this  eta {rate_s*(len(segments)-done)/60:4.1f}m",
                  flush=True)

    # Concatenate. 24 kbps VBR mono Opus: the model emits 22.05 kHz and Opus
    # resamples internally regardless, so a higher bitrate doubles storage for
    # a difference nobody hears through earbuds.
    listing = out_dir / "parts.txt"
    listing.write_text(
        "".join(f"file '{(parts_dir / f'{i:04d}.wav').as_posix()}'\n"
                for i in range(len(segments))),
        encoding="utf-8",
    )
    audio = out_dir / f"chapter-{plan['chapter']}.opus"
    ff = subprocess.run(
        ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(listing),
         "-c:a", "libopus", "-b:a", "24k", "-vbr", "on", "-ac", "1", str(audio)],
        capture_output=True, text=True,
    )
    if ff.returncode != 0:
        print("ffmpeg failed:", ff.stderr[-600:])
        return 1

    (out_dir / f"chapter-{plan['chapter']}.timing.json").write_text(
        json.dumps({"chapter": plan["chapter"], "sample_note": "durations measured, not estimated",
                    "total_ms": round(cursor_ms), "segments": timing}, indent=1),
        encoding="utf-8",
    )
    size = audio.stat().st_size
    print(f"\n{audio.name}  {size/1024:.0f} KiB  {cursor_ms/1000/60:.1f} min audio")
    print(f"render wall time {(time.time()-wall)/60:.1f} min  "
          f"RTF {(time.time()-wall)/(cursor_ms/1000):.2f}")
    print("RENDER_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
