# TTS: what the hardware actually does

Measured on the 3090 Ti box (Windows, 24,564 MiB) on 2026-09-19, with the Neiro
persona-LoRA trainer resident throughout. These numbers replace estimates in the
TTS plan; where they disagree, these win.

## The card can be shared, but only after the trainer is told to use less

| | free VRAM | note |
|---|---|---|
| trainer at `--batch 12 --accum 2` | 6,876 MiB | render worker's gate says **hold** — it would never start |
| trainer at `--batch 6 --accum 4` | 14,254 MiB | gate says **claim** |
| both loaded, mid-render | 8,345 MiB | trainer ~9.6 GB + IndexTTS ~5.5 GB |

`12 x 2` and `6 x 4` are both an effective batch of 24, so the gradient and the
run are unchanged; only activation memory halves. The trainer's own log confirms
it: `peak 9.64 GB` after the switch, against ~17.4 GB before, resuming from
`step 6850` with `--resume`.

**The batch size is not a property of the process.** It lives in
`D:\neiro-data\box_persona_train.bat`, run by the Windows scheduled task
`NeiroBoxPersonaTrain`, and Neiro re-chains that task when it exits. Killing the
trainer and starting a replacement with different flags therefore does nothing
lasting — the chainer relaunches from the `.bat` within seconds and the old
batch size returns. A first attempt did exactly that: it reported success and
left `--batch 12` running. Edit the `.bat`, restart the task.

## torch cannot be trusted for free VRAM on Windows

With the trainer holding 17.4 GB:

* `torch.cuda.mem_get_info()[0]` → **24.45 GB free** (essentially the whole card)
* `nvidia-smi --query-gpu=memory.free` → **6,876 MiB free** (true)

WDDM virtualizes VRAM and overcommits into system RAM, so the CUDA runtime does
not see another process's resident allocation. A gate built on `mem_get_info`
passes every time and OOMs the trainer — the exact failure it exists to prevent.
`services/gpu_gate.py` shells out to nvidia-smi for this reason, and treats
"cannot tell" as "do not claim".

## Render cost

One line, 6.11 s of speech, rendered while the trainer ran:

```
gpt_gen 7.65s · s2mel 2.43s · bigvgan 0.36s · total 11.14s · RTF 1.82
peak allocated 5.47 GB
```

**RTF 1.82 means slower than real time under contention** — roughly 1.8 minutes
of compute per minute of audio. A 20-minute chapter is therefore ~36 minutes of
GPU, not the "render a series overnight" the plan implies. Model load is a
further one-off per process, so the worker must be long-lived and batch chapters
rather than start per chapter.

## Output is 22,050 Hz, not 24,000

The plan specifies "24 kbps VBR mono Opus at 24 kHz — the model's native rate".
The model's native output rate is **22,050 Hz**. Opus resamples internally to
48 kHz regardless, so this changes nothing about the encode settings, but the
stated rate in the plan is wrong and the timing map must use 22,050 when
converting sample counts to seconds.

Reference clips are a separate matter: LibriTTS-R is 24 kHz and is used as-is
for the speaker prompt.

## Voice pack v1

12 clips from LibriTTS-R (CC BY 4.0, public-domain LibriVox), 6 male
(117–155 Hz) and 6 female (186–226 Hz), 6.0–11.5 s, 24 kHz mono, every clip
carrying a non-nullable `license` field. Built by `tools/tts/build_voice_pack.py`
from 37 candidate speakers.
