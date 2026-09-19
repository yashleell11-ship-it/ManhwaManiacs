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

**RTF 1.82 under contention** — 1.8 minutes of compute per minute of audio,
while the trainer held the card.

**RTF 0.63 on a free card.** Measured later on a full chapter (TBATE 119, 138
segments): 12.3 minutes of audio in 7.7 minutes of wall time, faster than real
time. Contention was costing roughly 3x. So the figure to plan against depends
entirely on whether the GPU is shared:

| | RTF | a 12-minute chapter | all 532 chapters |
|---|---|---|---|
| card shared with the trainer | 1.82 | ~22 min | ~200 h |
| card free | 0.63 | ~7.7 min | ~68 h |

Model load is a one-off per process either way, so the worker must be
long-lived and render whole chapters rather than starting per chapter.

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

## Cost, derived from the nine real runs

20,867 input and 206,522 output tokens over nine chapters, at `deepseek-flash`
list price ($0.30/M input cache-miss, $0.006/M cache-hit, $1.20/M output;
off-peak is half). About 85% of prompt tokens come back as cache hits after the
first request.

| | per chapter | TBATE, 532 ch | whole cache, 567 ch |
|---|---|---|---|
| peak | $0.0277 | $14.71 | $15.68 |
| off-peak | $0.0138 | $7.36 | $7.84 |

### …then cut by two thirds, by asking for less

Asking the model to name the rule it applied is what made it expensive. A
reasoning model thinks about the taxonomy as well as the text. Measured on
three real chapters, three prompts — seven rules, three tiers, and nothing but
"who speaks this line" — returned **byte-identical attributions**:

| chapter | 7 rules | 3 tiers | speaker only |
|---|---|---|---|
| 120 | $0.0063 | $0.0043 | **$0.0023** |
| 121 | — | $0.0066 | **$0.0031** |
| 122 | — | $0.0073 | **$0.0019** |

So the rule is no longer bought. It is assigned locally by `classify_span`,
which looks for a speech tag naming that speaker beside the quote — arithmetic,
the same argument that keeps offsets out of the model's hands, and checkable in
a way a model's self-assessment never was.

Cost after the change, off-peak: **$0.0024** for a typical chapter, $0.0084 for
a crowd scene, blended **$0.0045**.

| | off-peak |
|---|---|
| 1 chapter | $0.005 |
| 10 chapters | $0.045 |
| 100 chapters | $0.45 |
| all 532 of TBATE | **$2.40** |

The plan estimated $0.003/chapter. Output tokens are ~23x its "~900 out" figure,
but output is cheap, so the COST is 4.6x off-peak and 9.2x at peak. A full-series
bulk run is therefore a ~$7 decision off-peak, not a budget question. Off-peak
is 14:30-21:30 and 00:00-05:30 IST.

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


---

# The local model: measured, and what it cost

`qwen3:8b` (Q4_K_M, 5.2 GB) pulled to the desktop via ollama, tested against the
same chapters DeepSeek attributed.

## It killed a training run

Given the GPU, ollama reported **22.8 GiB "available"** on a card with ~11 GiB
actually free — the WDDM overcommit again, from a different runtime — loaded
against that figure, and took the card out from under a LoRA training run that
was **8,150 steps in**. Bounding context and `OLLAMA_MAX_LOADED_MODELS` did not
prevent it: the problem is not how much the client asks for, it is that the
server's own accounting cannot see another process.

`services/local_llm_client.py` therefore pins `num_gpu: 0`. The cost is latency
nobody waits on; the benefit is that the GPU stays entirely for TTS, which at
RTF 1.82 is the real bottleneck and is the one job that cannot run anywhere
else. Attribution can run anywhere — spending VRAM on it was spending the
scarce resource on the fungible task.

## The quality is not there yet

Chapter 123, where DeepSeek gives `Windsom 13, Arthur 9, Myre 8`:

| | qwen3:8b |
|---|---|
| usable labels | `I` ×9, `Windsom` ×5, `Myre` ×4, `She`, `His`, `As the asura` |
| dropped by `is_voice_candidate` | `he` ×2, `The asura`, `A deep, bass voice`, `A firm, deep voice` |

Nine spans answered `I` — it does not resolve first person to a name, which is
precisely the failure that made a chapter read entirely in one wrong voice
before. Pronouns and voice-descriptions account for most of the rest. A prompt
explicitly forbidding pronouns and descriptions did not change it.

108s per chapter on CPU, so ~16 hours for the series — free, but producing
attributions that would need discarding.

**Where this leaves it:** the 8B is not accurate enough. The 14B is — see below.

## qwen3:14b is good enough, and free

With the card idle (23.3 GB free), `qwen3:14b` Q4_K_M runs fully on GPU at
**12 s/chapter**. Measured against the DeepSeek attributions that survived
adversarial review 50/50, over 429 spans across 8 chapters — five two-handers
and three crowd scenes:

| | spans |
|---|---|
| agree on the character | 269 |
| **would produce a WRONG VOICE** | **13 (3.0%)** |
| local said a description (→ narration, not a wrong voice) | 6 |
| only local named a character | 49 |
| only DeepSeek named one | 70 |
| neither | 22 |

Coverage: **local 78%, DeepSeek 83%.**

Two things had to be fixed before this number meant anything. The first
comparison matched on the first word of a name and reported 30 "conflicts" that
were `Virion`/`Grandpa Virion` and `Mica`/`Lance Mica` — the same person. Those
ranks and familial forms are now in `_HONORIFICS`, with a guard so a name that
is ONLY a title ("The Lance") is not stripped to an empty key that every other
title-only name would collide with.

**11 of the 13 real conflicts are in one chapter.** Chapter 435 has no POV
header, so it was given the series narrator as a hint, and the model applied it
too widely — handing Arthur's mother's lines to Arthur. Outside that chapter the
rate is 2 in 429 (0.5%). The narrator hint helping a strong model and misleading
a weaker one is worth a follow-up: it should probably be withheld from a chapter
whose own text names another speaker in the same paragraph.

**Cost of attributing all 532 chapters:** ~107 minutes of otherwise-idle GPU,
and **$0**.


---

# One chapter of audio, end to end

TBATE chapter 119, rendered from a locally-attributed plan. Nothing paid for.

| | |
|---|---|
| segments | 138 (59 speech, 79 narration) |
| audio | 12.3 min, 2.2 MB |
| container | Opus, mono, 24,224 bps, 48 kHz |
| voices | narrator `libritts-2428` (98 segments), Myre `libritts-3853` (40) |
| render | 7.7 min wall, **RTF 0.63** |

**The timing map is contiguous — maximum gap between segments 0 ms, and
monotonic.** That is the whole payoff of rendering a sentence at a time: each
duration is `len(samples)/sample_rate`, measured rather than estimated, so the
highlight cannot drift from the audio.

Arthur is read by the narrator and has no voice of his own, which is correct
rather than a gap: he is the first-person POV, so he and the narrator are the
same person.


---

# Six chapters, end to end, for nothing

TBATE 118-123, attributed by the local 14B and rendered on the 3090 Ti.

| chapter | minutes | segments | voices | contiguous | drift |
|---|---|---|---|---|---|
| 118 | 12.6 | 146 | 2 | yes | 0.01 s |
| 119 | 12.3 | 138 | 2 | yes | 0.01 s |
| 120 | 13.9 | 152 | 2 | yes | 0.01 s |
| 121 | 11.3 | 126 | 3 | yes | 0.01 s |
| 122 | 16.0 | 222 | 3 | yes | 0.01 s |
| 123 | 14.9 | 172 | 3 | yes | 0.01 s |

**956 segments, 81 minutes, 14.1 MB, $0.** Every timing map is contiguous and
monotonic, and each one lands within 0.01 s of its Opus file across a whole
chapter.

Cast across the six: the narrator reads Arthur (first-person POV), with Myre,
Windsom and Wren each on their own clip.

## Verified in a browser, not only in tests

Chapter 119 opened in the reader with 138 segment nodes and 40 tinted spans —
matching its timing map exactly. Playing it:

| time | segment | highlighted |
|---|---|---|
| 7.9 s | 1 | "An indescribably chilling sensation burst out from within my mana core" |
| 96.4 s | 14 | "Her soft purple eyes peered through me…" |
| 301.4 s | 51 | "…she continued, smiling gently at me." |

Exactly one element carries the highlight at any moment.

That run also caught what unit tests could not: `<audio src={url}>` returns
**401 in dev**, because `mm_session` is httpOnly and SameSite=lax and a
browser-managed subresource request to another origin never carries it — the
failure `services/http.ts` already records as having taken `next/image`'s
optimizer out app-wide. The player goes through `requestBlob` instead.
