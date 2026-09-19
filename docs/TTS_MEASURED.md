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

---

# Attribution: what the model actually does

Measured on 2026-09-19 over nine real cached chapters of *The Beginning After
The End* (603 quoted spans), using `deepseek-flash`.

## DeepSeek has no non-reasoning model any more

`/models` lists exactly `deepseek-flash` and `deepseek-v4-pro`. `deepseek-chat`
is gone; a request for it still answers but comes back stamped `deepseek-flash`.
Both models reason before replying and bill that reasoning as OUTPUT tokens.

Measured output per request (reasoning included):

| spans asked | reasoning | total out |
|---|---|---|
| 8 | 11,062 | 11,177 |
| 26 | 20,567 | 21,089 |
| 26 (v4-pro) | 12,070 | 12,618 |
| 97 | ~21,600 | 21,593 |

Roughly **10k fixed per request plus ~0.4k per span**. The fixed part is the
argument against batching a chapter: two half-chapters cost more than one whole
one. `max_tokens` is set to 48,000 and covers the busiest chapter seen.

JSON mode and the system prompt are both load-bearing. Dropping either made the
reasoning fail to terminate at all (16,000 tokens, `finish_reason: length`,
empty content) in two separate runs.

The plan's "~6,400 in / ~900 out, $0.003/chapter" is wrong by more than an
order of magnitude on output. Cost per chapter needs re-deriving from these
numbers against current pricing before any bulk run.

## Coverage

| set | chapters | spans | attributed | distinct speakers |
|---|---|---|---|---|
| two-handers (118-123) | 6 | 266 | 202 (75%) | 4 |
| crowd scenes (371, 435, 498) | 3 | 337 | 301 (89%) | 41 |

Crowd scenes do **better**, not worse: a scene with eight people in it carries
explicit speech tags, while a two-hander leans on alternation and expects the
reader to keep track.

## The failure that mattered

Where the model did not establish a first-person narrator it gave **every**
confident line to the one other character named in the text — 29 of 29 in one
chapter, 19 of 19 in another. The cause is structural: a first-person narrator
is almost never named inside his own chapter, so there is nobody for his
dialogue to be assigned to.

Fixed by carrying the series' known narrator into the prompt and by asking every
request who narrates *this* chapter, so the series learns it from the first
chapter that makes it obvious. Verified from an empty database, in order:
chapter 121 established "Arthur"; chapter 122 went from 19-of-19 wrong to a
correct Myre 12 / Arthur 8; a second pass over 120 went from 29 Myre / 0 Arthur
to 30 Myre / 12 Arthur.

## Adversarial verification

50 spans stratified across rules 1-3 and four speakers, judged twice — once by a
pass told to refute the claim, once blind. **50/50 correct, no disagreement.**

Carried caveats from that review, which are not resolved:

* 0/50 bounds the true error rate at roughly **6%** (rule of three, 95%), not at
  zero. At 6% a listener hears a wrong voice about once every 17 lines.
* Both passes come from the same model family and share reasoning habits, so
  agreement is weaker evidence than two genuinely independent samples.
* 8-10 of the 50 had no inline tag and were resolved by inference.

That pass also found a real extractor bug, since fixed: a scare-quoted phrase
was being read as dialogue.

## Speaker labels are not all characters

Observed verbatim: `"Wren Kain, Lyra, and Mordain"`, `"Linden, Brion, and
Pascal"`, `"the voice"` (8 lines), `"the unseen announcer"` (3), `"the
announcer"` (1) — three labels for one entity — `"the crowd"`, `"a middle-aged
woman"`. Also `"Wren"` and `"Wren Kain"` for one character across chapters.

Spans keep whatever label the model gave, because it is true. But
`is_voice_candidate()` stops a group or a description ever becoming a cast
member: those lines are narrated. A line shared by three people reads correctly
in the narrator's voice and absurdly in anyone else's.
