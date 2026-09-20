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
from services.novel_dialogue import normalize_name  # noqa: E402


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
    gender_of = {c.normalized_name: c.gender for c in cast}

    def narrator_clip(who: str | None) -> str:
        """The flattest clip matching this chapter's narrator.

        PER CHAPTER, not per series. A book that rotates POV has a different
        narrator in different chapters, and reading a woman's chapter in the
        series' default male voice is wrong in a way no amount of correct
        character casting makes up for.
        """
        gender = gender_of.get(normalize_name(who or ""), "unknown")
        if gender not in ("male", "female"):
            gender = "male"
        pool = [c for c in pack["clips"] if c["gender"] == gender]
        return sorted(pool, key=lambda c: c["pitch_spread"])[0]["voice_id"]

    # Every clip a narrator could use is reserved, so no character is ever
    # given a voice that reads as narration somewhere else in the book.
    narrators = {
        narrator_clip(w)
        for w in {pov}
        | {
            attribution.read_attribution(
                db, source_id, series_key, c["chapter_key"]
            ).get("narrator")
            for c in chapters
        }
    }
    # Whether the series POV narrates EVERY chapter decides whether they need
    # a character voice at all.
    #
    # In a single-POV book they never speak in anyone else's chapter, so a
    # voice for them is a wasted slot out of twelve. In a book that rotates,
    # they do — and excluding them here was a real bug: the series' busiest
    # speaker, with 175 lines across six chapters, held NO voice and so read
    # in the narrator's own voice through all seven chapters somebody else
    # narrated. The per-chapter exclusion below is what implements "the
    # narrator reads their own dialogue"; doing it here as well is what broke
    # it.
    narrated = [
        attribution.read_attribution(
            db, source_id, series_key, c["chapter_key"]
        ).get("narrator")
        for c in chapters
    ]
    told = [n for n in narrated if n]
    sole = pov if told and all(
        normalize_name(n) == normalize_name(pov or "") for n in told
    ) else None
    voices = assign_voices(
        [(c.display_name, c.gender) for c in cast],
        [(c["voice_id"], c["gender"]) for c in pack["clips"] if c["voice_id"] not in narrators],
        pov=sole,
    )
    print(f"\nnarrator clips reserved: {sorted(narrators)}")
    print(f"character voices: {voices}")

    # Persist the assignment. Without this the DATABASE says every character
    # reads as narrator while the AUDIO gives them their own voice, and the
    # reader's cast list — which reads the database — contradicts what the
    # listener hears. The column exists for exactly this.
    #
    # A locked row is an owner's decision and is left alone.
    #
    # Clearing matters as much as setting. This loop used to write only when
    # `assigned` was truthy, so a character who lost their voice to a changed
    # cast kept the old one — and the next character in line was handed the
    # same clip. Measured on the real series: re-running after the POV changed
    # gave Arthur and Wren BOTH libritts-251, which is worse than the bug it
    # would have been fixing.
    for member in cast:
        assigned = voices.get(member.normalized_name)
        if not member.locked and member.voice_id != assigned:
            member.voice_id = assigned
    db.commit()

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
        chapter_narrator = record.get("narrator") or pov
        narrator = narrator_clip(chapter_narrator)
        # This chapter's narrator reads their own dialogue; they get no second
        # voice. Any OTHER chapter's narrator is an ordinary character here.
        chapter_voices = {
            k: v for k, v in voices.items() if k != normalize_name(chapter_narrator or "")
        }
        plan = plan_chapter(chapter["paragraphs"], spans, chapter_voices)
        used = set(chapter_voices.values()) | {narrator}
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
        print(f"  #{number} {len(plan):>4} segments, {voiced} in a character voice, "
              f"narrated by {chapter_narrator} ({narrator})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
