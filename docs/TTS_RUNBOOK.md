# Making an audiobook out of a novel

Everything below runs on the desktop's GPU and costs nothing. The paid API is
a fallback, used only when no local model is reachable.

## What has to be running

| | where | how |
|---|---|---|
| `ollama` with `qwen3:14b` | the desktop | scheduled task `MMOllamaServe` |
| a tunnel to it | the laptop | `tools/tts/render-watchdog.sh` keeps the render going; the tunnel is `ssh -N -L 11434:127.0.0.1:11434 box-lan` |
| IndexTTS-2.5 | `D:\models\IndexTTS-2.5` | with `D:\index-tts` and its `uv` environment |
| a voice pack | `D:\models\voicepack-v1-full` | built by `tools/tts/build_voice_pack.py` |

The desktop is reached as `box-lan` (the ethernet cable, sub-millisecond) or
`box` (tailscale). The cable is tried first everywhere.

## 1. Pull the chapters

Chapter text lives in `novel_chapter_cache` on the VPS. Export the ones you
want as `{source_id, series_key, chapters: [{chapter_key, title, number,
paragraphs, word_count}]}`.

**Only ever attribute chapters that are already cached.** `GET /novels/chapter`
is a 7-day LRU that refetches on a miss, so a bulk pass over uncached chapters
is a live scrape of the source — which is how Toonily and Bbato got their
egress blocked.

## 2. Attribute and plan

```bash
cd backend && . .venv/bin/activate
export MM_DB_PATH=/path/to/series.db
export MM_LOCAL_LLM_GPU_LAYERS=999 MM_LOCAL_LLM_MODEL=qwen3:14b
python ../tools/tts/attribute_and_plan.py \
  --chapters chapters.json \
  --voices /home/yash/models/voicepack/v1-full/manifest.json \
  --out plans/ --pov "Arthur"
```

`--pov` is only a hint for the first chapter; after that the series learns its
own narrator. Run it over the WHOLE set you intend to render, not chapter by
chapter: gender is decided once from all the evidence, and a character whose
voice changes between chapters is worse than one who never had a distinct
voice.

`MM_LOCAL_LLM_GPU_LAYERS=999` puts the model on the GPU. **Leave it unset when
anything else is using the card** — the default is CPU, and it is the default
because ollama's own accounting cannot see another process's VRAM and took the
card out from under a training run that was 8,150 steps in.

Attribution is cached on the text's fingerprint, so re-running costs nothing
for chapters that have not changed.

## 3. Render

Copy the plans to `D:\models\` and run `tools/tts/render_plan.py` per plan, or
let the batch task do it. `tools/tts/render-watchdog.sh` (systemd timer, every
five minutes) restarts the batch if the desktop reboots or drops off, and
disables the Neiro training task if it comes back — it has a boot trigger and
re-chains itself.

Expect **RTF 0.63 on a free card** — about 8 minutes of GPU per 12-minute
chapter — and roughly 1.8x that if something else is using it.

## 4. Serve it

Put `chapter-N.opus` and `chapter-N.timing.json` where the store expects them:

```python
from services.chapter_audio_store import chapter_paths
audio, timing = chapter_paths(source_id, series_key, chapter_key)
```

Paths are hashed from the identity triple, so connector keys containing slashes
are safe. Set `MM_AUDIO_DIR` if the store is not beside `settings.json`.

The reader then finds it on its own: `GET /novels/audio` for the timing map,
`GET /novels/audio/file` for the Opus.

## Correcting what it got wrong

```
POST /novels/cast        {source_id, series_key, name, gender?, voice_id?}
POST /novels/cast/alias  {source_id, series_key, alias, canonical}
```

The alias is the powerful one. Spans store a speaker LABEL and resolve at serve
time, so `"King Grey" is Arthur` is a single row that corrects every chapter
ever attributed — including ones rendered months ago — without re-attributing
or rewriting anything.

A correction marks the row `locked`, and nothing automatic will overwrite it
afterwards.

## When a character has no voice

Expected, not broken. A character is narrated when their gender could not be
established from pronouns, when the voice pack has no free clip of that gender,
or when they are the chapter's own narrator — in a first-person book the
narrator and the POV character are the same person, and every audiobook reads
their dialogue in the narrator's voice.

A wrong voice is worse than a plain one, so anything uncertain is narrated.
