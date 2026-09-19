"""Cut speaker reference clips for IndexTTS-2.5 out of LibriTTS-R.

IndexTTS clones the voice in a reference clip, so the clip IS the product
decision. Two rules are enforced here rather than left to judgement:

**Every clip carries a licence, and the field is not nullable.** That is the
enforcement mechanism for the rule that matters: never clone a commercial
narrator, a voice actor, a streamer, or a family member. Right-of-publicity
statutes bite, and it is indefensible beyond a private household. LibriTTS-R is
CC BY 4.0 over public-domain LibriVox recordings, which is why it is the source.

**Clips are chosen to be emotionally FLAT.** IndexTTS-2.5 disentangles emotion
from speaker identity, which means an expressive reference does not make the
output expressive -- it bleeds a permanent colour into every line that voice
ever reads. Clips are scored on pitch stability and the flattest win, RANKED
within each gender rather than filtered against a fixed threshold -- a constant
tight enough to be meaningful is also tight enough to empty a bucket without
saying so.

Gender is bucketed from median F0 rather than from metadata, because the
speaker tables are not served alongside the audio. The same discipline the
character code uses applies: a speaker whose pitch sits in the overlap is
recorded as ``unknown`` and simply not used, never coin-flipped into a bucket.

Usage:
    python build_voice_pack.py <parquet...> --out DIR [--per-gender 6]
"""

from __future__ import annotations

import argparse
import io
import json
import math
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

LICENSE = "CC BY 4.0"
ATTRIBUTION = "LibriTTS-R (Koizumi et al., 2023), derived from LibriVox public-domain audiobooks"
SOURCE = "mythicinfinity/libritts_r"

#: IndexTTS wants a reference long enough to characterise a voice and short
#: enough not to drag other prosody in with it.
MIN_SECONDS = 6.0
MAX_SECONDS = 12.0

#: Adult speaking ranges, with the overlap deliberately left unassigned.
MALE_MAX_HZ = 155.0
FEMALE_MIN_HZ = 185.0

#: A sanity ceiling only -- clips above this are erratic enough to be a
#: detection failure rather than a reading. The ACTUAL selection ranks by
#: spread within each gender and takes the flattest, which is what stops a
#: badly-chosen constant from silently emptying a bucket: a threshold of 0.22
#: rejected five of eight speakers here and happened to remove both male
#: voices, producing a "voice pack" with no men in it and no error.
MAX_PITCH_SPREAD = 0.50


def median_f0(samples: np.ndarray, rate: int) -> tuple[float, float]:
    """(median F0, relative spread) over voiced frames, by autocorrelation.

    Deliberately simple and dependency-free: this decides which bucket a voice
    goes in and whether it is flat enough to use, not anything a listener hears
    directly.
    """
    frame = int(0.040 * rate)
    hop = int(0.020 * rate)
    lo = int(rate / 400.0)  # 400 Hz
    hi = int(rate / 60.0)   # 60 Hz
    if samples.size < frame:
        return 0.0, 1.0

    energies = []
    pitches = []
    for start in range(0, samples.size - frame, hop):
        window = samples[start : start + frame]
        energy = float(np.sqrt(np.mean(window ** 2)))
        if energy < 1e-3:
            continue
        window = window - window.mean()
        corr = np.correlate(window, window, mode="full")[frame - 1 :]
        if corr[0] <= 0:
            continue
        segment = corr[lo:hi]
        if segment.size == 0:
            continue
        lag = int(np.argmax(segment)) + lo
        # A voiced frame has a clear periodic peak; noise does not.
        if corr[lag] < 0.3 * corr[0]:
            continue
        pitches.append(rate / lag)
        energies.append(energy)

    if len(pitches) < 8:
        return 0.0, 1.0
    values = np.array(pitches)
    median = float(np.median(values))
    # Robust spread: inter-quartile range relative to the median, so one
    # octave-error frame does not condemn an otherwise level clip.
    q75, q25 = np.percentile(values, [75, 25])
    spread = float((q75 - q25) / median) if median else 1.0
    return median, spread


def bucket(f0: float) -> str:
    if f0 <= 0:
        return "unknown"
    if f0 <= MALE_MAX_HZ:
        return "male"
    if f0 >= FEMALE_MIN_HZ:
        return "female"
    # The overlap. Recorded, never guessed.
    return "unknown"


def candidates(paths: list[Path]):
    """Yield (speaker_id, duration, samples, rate, text) for usable rows."""
    for path in paths:
        parquet = pq.ParquetFile(path)
        for group in range(parquet.metadata.num_row_groups):
            table = parquet.read_row_group(
                group, columns=["audio", "speaker_id", "text_normalized"]
            )
            for row in table.to_pylist():
                raw = row["audio"]["bytes"]
                try:
                    samples, rate = sf.read(io.BytesIO(raw), dtype="float32")
                except Exception:
                    continue
                if samples.ndim > 1:
                    samples = samples.mean(axis=1)
                duration = samples.size / rate
                if not MIN_SECONDS <= duration <= MAX_SECONDS:
                    continue
                yield row["speaker_id"], duration, samples, rate, row["text_normalized"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("parquet", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--per-gender", type=int, default=6)
    args = ap.parse_args()

    best: dict[str, dict] = {}
    for speaker, duration, samples, rate, text in candidates(args.parquet):
        f0, spread = median_f0(samples, rate)
        if spread > MAX_PITCH_SPREAD:
            continue  # performing, not reading
        gender = bucket(f0)
        if gender == "unknown":
            continue
        current = best.get(speaker)
        # One clip per speaker: the flattest one.
        if current is None or spread < current["spread"]:
            best[speaker] = {
                "speaker": speaker, "f0": f0, "spread": spread,
                "gender": gender, "duration": duration,
                "samples": samples, "rate": rate, "text": text,
            }

    chosen: list[dict] = []
    for gender in ("male", "female"):
        pool = sorted(
            (v for v in best.values() if v["gender"] == gender),
            key=lambda v: v["spread"],
        )
        chosen.extend(pool[: args.per_gender])

    args.out.mkdir(parents=True, exist_ok=True)
    manifest = []
    for entry in chosen:
        name = f"{entry['gender']}-{entry['speaker']}.wav"
        sf.write(args.out / name, entry["samples"], entry["rate"], subtype="PCM_16")
        manifest.append({
            "voice_id": f"libritts-{entry['speaker']}",
            "file": name,
            "gender": entry["gender"],
            "median_f0_hz": round(entry["f0"], 1),
            "pitch_spread": round(entry["spread"], 3),
            "seconds": round(entry["duration"], 2),
            "sample_rate": entry["rate"],
            # Not nullable. This field is the enforcement mechanism.
            "license": LICENSE,
            "attribution": ATTRIBUTION,
            "source_dataset": SOURCE,
            "speaker_consent": "public-domain recording, not a private individual",
            "transcript": entry["text"],
        })

    (args.out / "manifest.json").write_text(
        json.dumps({"clips": manifest}, indent=2), encoding="utf-8"
    )
    males = sum(1 for m in manifest if m["gender"] == "male")
    females = len(manifest) - males
    pool_m = sum(1 for v in best.values() if v["gender"] == "male")
    pool_f = sum(1 for v in best.values() if v["gender"] == "female")
    print(f"speakers found: {pool_m} male, {pool_f} female")
    print(f"wrote {len(manifest)} clips ({males} male, {females} female) to {args.out}")
    if not males or not females:
        # Said out loud: a one-gendered pack is a broken pack, and the failure
        # is silent otherwise.
        print("WARNING: a gender bucket is EMPTY -- the pack is unusable as is")


if __name__ == "__main__":
    main()
