"""Attribute a series' chapters, then plan their audio — in that order.

The order is the point. Attribution is per chapter, but the CAST is per series,
and gender can only be decided once all the evidence is in. A character with
she=21 in one chapter scored she=4 in another and came out "unknown" there,
losing her voice for that chapter alone — and a character whose voice changes
between chapters is a worse artefact than one who never had a distinct voice.

So: attribute everything, accumulate the cast, assign voices once, and only
then plan. Running per chapter would make the voice depend on which chapter
happened to be processed.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))

from database.session import SessionLocal  # noqa: E402
from services import novel_attribution_service as attribution  # noqa: E402
from services.novel_audio_plan import (  # noqa: E402
    SpeechSpan,
    assign_voices,
    plan_chapter,
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--chapters", required=True, help="JSON with {source_id, series_key, chapters:[...]}")
    ap.add_argument("--voices", required=True, help="voice pack manifest.json")
    ap.add_argument("--out", required=True, help="directory to write plans into")
    ap.add_argument("--pov", default=None, help="series narrator, if already known")
    args = ap.parse_args()

    payload = json.loads(Path(args.chapters).read_text(encoding="utf-8"))
    source_id, series_key = payload["source_id"], payload["series_key"]
    chapters = payload["chapters"]

    db = SessionLocal()
    if args.pov:
        attribution.record_narrator(db, source_id, series_key, args.pov)
        db.commit()

    print(f"attributing {len(chapters)} chapters", flush=True)
    for chapter in chapters:
        started = time.time()
        row = attribution.attribute_chapter(
            db, source_id, series_key, chapter["chapter_key"], chapter["paragraphs"]
        )
        db.commit()
        spans = json.loads(row.spans) if row.spans else []
        named = sum(1 for s in spans if s["speaker"])
        print(f"  #{chapter.get('number', '?')} {row.status:<9} "
              f"{named}/{len(spans)} named  {time.time()-started:.0f}s", flush=True)

    # One cast for the whole series, gender decided from all of it at once.
    cast = attribution.build_series_cast(db, source_id, series_key)
    db.commit()
    pov = attribution.series_pov(db, source_id, series_key)
    print(f"\ncast ({len(cast)}), narrator = {pov}")
    for member in cast[:15]:
        print(f"  {member.display_name:<22} {member.gender:<8} "
              f"{member.line_count:>4} lines  {member.chapter_count} ch")

    pack = json.loads(Path(args.voices).read_text(encoding="utf-8"))
    clips = {c["voice_id"]: c for c in pack["clips"]}
    # The narrator is the flattest clip of the POV character's gender when that
    # is known, and male by default — a choice worth revisiting per series.
    pov_gender = next(
        (c.gender for c in cast if pov and c.normalized_name == pov.lower()), "male"
    )
    pool = [c for c in pack["clips"] if c["gender"] == (pov_gender if pov_gender != "unknown" else "male")]
    narrator = sorted(pool, key=lambda c: c["pitch_spread"])[0]["voice_id"]

    voices = assign_voices(
        [(c.display_name, c.gender) for c in cast],
        [(c["voice_id"], c["gender"]) for c in pack["clips"]],
        pov=pov, narrator_voice=narrator,
    )
    print(f"\nnarrator {narrator} (reserved)   character voices: {voices}")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    for chapter in chapters:
        record = attribution.read_attribution(
            db, source_id, series_key, chapter["chapter_key"]
        )
        if not record["attributed"]:
            print(f"  #{chapter.get('number','?')} skipped (not attributed)")
            continue
        spans = [SpeechSpan(s["p"], s["s"], s["e"], s["speaker"]) for s in record["spans"]]
        plan = plan_chapter(chapter["paragraphs"], spans, voices)
        used = set(voices.values()) | {narrator}
        number = chapter.get("number", chapter["chapter_key"])
        (out_dir / f"plan{number}.json").write_text(json.dumps({
            "chapter": str(number), "title": chapter.get("title", ""),
            "narrator_voice": narrator,
            "voice_files": {v: clips[v]["file"] for v in used},
            "segments": [{"i": i, "text": s.text, "voice": s.voice_id or narrator,
                          "speaker": s.speaker, "p": s.paragraph, "s": s.start,
                          "e": s.end, "speech": s.is_speech}
                         for i, s in enumerate(plan)],
        }, indent=1), encoding="utf-8")
        voiced = sum(1 for s in plan if s.voice_id)
        print(f"  #{number} {len(plan):>4} segments, {voiced} in a character voice")
    return 0


if __name__ == "__main__":
    sys.exit(main())
