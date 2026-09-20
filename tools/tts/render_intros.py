"""Have every voice in the pack introduce itself, so a person can choose one.

A listener cannot pick a voice from a number. ``libritts-2803`` at 103 Hz says
nothing about whether you want to spend four hundred chapters with it, and the
reference clip is a stranger reading a sentence from a nineteenth-century novel
about somebody else's house — it demonstrates the timbre and nothing else.

So each voice says the same short script, rendered through the same model that
will read the book. What comes back IS the product: the same conditioning clip,
the same inference path, so a preview cannot flatter a voice the renderer will
not reproduce.

The script is written to exercise what actually differs between these voices
over a long book: a level statement, a question, and a line of dialogue. About
twenty seconds each. It names the voice, because the name is what the picker
shows and hearing it said is how it sticks.

Usage (on the render box):
    python render_intros.py --pack D:\\models\\voicepack-v3 --out D:\\models\\intros
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

#: Second person, because the listener is choosing, not being sold to. No
#: adjectives about the voice itself -- it is demonstrating them, and a clip
#: that claims to be "warm" while sounding thin is worse than one that claims
#: nothing.
SCRIPT = (
    "Hello. My name is {name}. If you pick me, I'll be the one reading to "
    "you — the narration, or one of the people in it. This is roughly how I "
    "sound at an even pace, reading a plain line of prose. And this is how I "
    "sound when a sentence turns into a question, or when someone speaks. "
    "\"Then we go,\" he said, \"and we don't come back.\" That's me. Take "
    "your time deciding."
)


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
    ap.add_argument("--pack", required=True, help="voice pack dir with manifest.json")
    ap.add_argument("--out", required=True)
    ap.add_argument("--claim-mb", type=int, default=8192)
    ap.add_argument("--fraction", type=float, default=0.30)
    ap.add_argument("--only", default=None, help="one voice_id, for a retry")
    args = ap.parse_args()

    pack = Path(args.pack)
    clips = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))["clips"]
    if args.only:
        clips = [c for c in clips if c["voice_id"] == args.only]
    if not clips:
        print("nothing to render")
        return 2

    # Same gate the chapter renderer uses, and for the same reason: free
    # memory comes from nvidia-smi because under Windows WDDM the CUDA
    # runtime reports the whole card free while a trainer holds most of it.
    free = free_vram_mb()
    if free is None or free < args.claim_mb:
        print(f"REFUSING: need {args.claim_mb} MiB free, have {free}")
        return 2

    import torch
    if torch.cuda.is_available():
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
    out_dir.mkdir(parents=True, exist_ok=True)
    import soundfile as sf

    done = []
    for index, clip in enumerate(clips):
        name = clip.get("name") or clip["voice_id"]
        target = out_dir / f"{clip['voice_id']}.wav"
        began = time.time()
        tts.infer(
            spk_audio_prompt=str(pack / clip["file"]),
            text=SCRIPT.format(name=name),
            output_path=str(target), lang="en", verbose=False,
        )
        data, rate = sf.read(target)
        seconds = len(data) / rate
        done.append({"voice_id": clip["voice_id"], "name": name,
                     "seconds": round(seconds, 2)})
        print(f"  {index + 1}/{len(clips)}  {name:<10} {seconds:5.1f}s audio "
              f"in {time.time() - began:5.1f}s", flush=True)

    (out_dir / "intros.json").write_text(
        json.dumps({"script": SCRIPT, "intros": done}, indent=1), encoding="utf-8")
    total = sum(d["seconds"] for d in done)
    print(f"\n{len(done)} intros, {total / 60:.1f} minutes of audio")
    return 0


if __name__ == "__main__":
    sys.exit(main())
