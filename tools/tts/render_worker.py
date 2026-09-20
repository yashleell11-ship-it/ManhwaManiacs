"""The render box: take a chapter, narrate it, send it back.

Runs on the Windows desktop with the 3090 Ti. It polls because it has to —
the machine sits behind a home NAT and is asleep half the time, so the server
cannot call it. It asks; the server answers or says there is nothing.

Three things this deliberately does NOT do.

**It holds no database and makes no casting decisions.** The plan arrives
frozen from the server, which is the only place that knows the whole series'
cast and the owner's voice choices. The worker renders exactly the segments it
is handed, which is what makes a render reproducible.

**It never takes the card from a trainer.** Free VRAM comes from nvidia-smi,
never from ``torch.cuda.mem_get_info`` — under Windows WDDM the CUDA runtime
cheerfully reports the whole 24 GB free while a trainer holds seventeen of it.
Below the floor it releases the job rather than failing it, so a training run
costs a chapter no retries.

**It never leaves a half-written chapter.** Audio is uploaded only after every
segment is rendered and concatenated. A worker killed mid-chapter loses its
lease, the server puts the job back, and nothing partial was ever published.

Usage:
    python render_worker.py --server https://… --token … --pack D:\\models\\voicepack-v3
"""

from __future__ import annotations

import argparse
import io
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import urllib.error
import urllib.request

#: Claim only with this much VRAM free. IndexTTS wants about 6 GB; the margin
#: keeps a trainer that grows slightly from being pushed into paging.
CLAIM_FLOOR_MB = 8192

#: Release the job below this. Deliberately lower than the claim floor so a
#: render already in progress is not abandoned over a brief spike.
RELEASE_FLOOR_MB = 6500

#: How often to tell the server we are alive. Well inside the lease, and often
#: enough that a cancel reaches us within half a minute.
HEARTBEAT_EVERY = 25.0

#: Nothing to do. Long enough not to hammer a 2-core VPS, short enough that
#: queuing a chapter feels like it started.
IDLE_SLEEP = 30.0


def free_vram_mb() -> int | None:
    """Free VRAM per nvidia-smi, which is the only source that tells the truth.

    Measured on this box: with a trainer holding 17.4 GB,
    ``torch.cuda.mem_get_info()`` reported 24.45 GB free and nvidia-smi
    reported 6,876 MiB. Windows WDDM virtualises VRAM and lets it overcommit,
    so the CUDA runtime cannot see another process's resident allocation.
    """
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


class Server:
    """The queue, over HTTP. Deliberately stdlib — this box has no venv to
    keep in sync with the server's."""

    def __init__(self, base: str, token: str, worker_id: str) -> None:
        self.base = base.rstrip("/")
        self.token = token
        self.worker_id = worker_id

    def _post(self, path: str, payload: dict, *, timeout: float = 60.0):
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base}{path}", data=body, method="POST",
            headers={
                "Content-Type": "application/json",
                "X-Render-Token": self.token,
            },
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status == 204:
                return None
            raw = response.read()
            return json.loads(raw) if raw else None

    def claim(self) -> dict | None:
        return self._post("/novels/render/claim", {"worker_id": self.worker_id})

    def heartbeat(self, job_id: str, done: int) -> dict | None:
        return self._post("/novels/render/heartbeat", {
            "job_id": job_id, "worker_id": self.worker_id, "segments_done": done,
        })

    def fail(self, job_id: str, code: str, detail: str, *, retryable=True) -> None:
        self._post("/novels/render/fail", {
            "job_id": job_id, "worker_id": self.worker_id, "code": code,
            "detail": detail[:2000], "retryable": retryable,
        })

    def release(self, job_id: str, reason: str) -> None:
        self._post("/novels/render/release", {
            "job_id": job_id, "worker_id": self.worker_id, "reason": reason[:200],
        })

    def complete(self, job_id: str, audio: Path, timing: Path) -> dict | None:
        """Upload the chapter as multipart, hand-rolled to avoid a dependency."""
        boundary = "----mmrender" + os.urandom(8).hex()
        parts: list[bytes] = []

        def field(name: str, value: str) -> None:
            parts.append(
                f"--{boundary}\r\nContent-Disposition: form-data; "
                f'name="{name}"\r\n\r\n{value}\r\n'.encode()
            )

        def file_part(name: str, path: Path, mime: str) -> None:
            parts.append(
                f"--{boundary}\r\nContent-Disposition: form-data; "
                f'name="{name}"; filename="{path.name}"\r\n'
                f"Content-Type: {mime}\r\n\r\n".encode()
            )
            parts.append(path.read_bytes())
            parts.append(b"\r\n")

        field("job_id", job_id)
        field("worker_id", self.worker_id)
        file_part("audio", audio, "audio/ogg")
        file_part("timing", timing, "application/json")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)

        request = urllib.request.Request(
            f"{self.base}/novels/render/complete", data=body, method="POST",
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "X-Render-Token": self.token,
            },
        )
        with urllib.request.urlopen(request, timeout=600) as response:
            raw = response.read()
            return json.loads(raw) if raw else None


class Renderer:
    """IndexTTS, loaded once and kept.

    Loading costs the better part of a minute, so a worker that reloaded per
    chapter would spend more time loading than rendering on a short one.
    """

    def __init__(self, model_dir: str, pack: Path, fraction: float) -> None:
        self.pack = pack
        self.manifest = {
            clip["voice_id"]: clip
            for clip in json.loads(
                (pack / "manifest.json").read_text(encoding="utf-8")
            )["clips"]
        }
        import torch

        if torch.cuda.is_available():
            # If this process is wrong about how much room it has, the
            # allocation that fails must be ITS OWN. The trainer has hours
            # invested; a chapter has minutes.
            torch.cuda.set_per_process_memory_fraction(fraction, 0)
        from indextts.infer_v2_5 import IndexTTS2

        began = time.time()
        self.tts = IndexTTS2(
            cfg_path=str(Path(model_dir) / "config.yaml"), model_dir=model_dir,
            use_bf16=True, device="cuda:0", use_cuda_kernel=False,
        )
        print(f"model loaded in {time.time() - began:.0f}s", flush=True)

    def reference(self, voice_id: str) -> Path:
        """The conditioning clip for a voice, from THIS box's pack.

        Resolved locally rather than sent by the server: the plan carries
        voice ids, and the box knows where its own files are. A server that
        sent paths would be sending paths for a filesystem it cannot see.
        """
        clip = self.manifest.get(voice_id)
        if clip is None:
            raise KeyError(f"voice {voice_id} is not in this box's pack")
        return self.pack / clip["file"]

    def render(self, plan: dict, out_dir: Path, on_segment) -> tuple[Path, Path]:
        """Render every segment, concatenate, and write the timing map.

        The duration of each segment IS the measurement — it is the length of
        the samples that came back — so the timing map cannot drift from the
        audio. Nothing here estimates anything.
        """
        import soundfile as sf

        parts_dir = out_dir / "parts"
        parts_dir.mkdir(parents=True, exist_ok=True)
        segments = plan["segments"]

        timing: list[dict] = []
        cursor_ms = 0.0
        rate = 0
        chunks = []

        for index, segment in enumerate(segments):
            target = parts_dir / f"{index:05d}.wav"
            self.tts.infer(
                spk_audio_prompt=str(self.reference(segment["voice"])),
                text=segment["text"], output_path=str(target),
                lang="en", verbose=False,
            )
            data, rate = sf.read(target, dtype="float32")
            chunks.append(data)
            seconds = len(data) / rate
            timing.append({
                "i": segment["i"],
                "start_ms": round(cursor_ms),
                "end_ms": round(cursor_ms + seconds * 1000),
                "p": segment["p"], "s": segment["s"], "e": segment["e"],
                "voice": segment["voice"], "speaker": segment.get("speaker"),
                "speech": segment["speech"],
            })
            cursor_ms += seconds * 1000
            if not on_segment(index + 1):
                raise Cancelled()

        import numpy as np

        joined = np.concatenate(chunks) if chunks else np.zeros(0, dtype="float32")
        wav = out_dir / "chapter.wav"
        sf.write(wav, joined, rate)

        opus = out_dir / "chapter.opus"
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav),
             "-c:a", "libopus", "-b:a", "24k", "-ac", "1", str(opus)],
            check=True,
        )
        timing_path = out_dir / "chapter.timing.json"
        timing_path.write_text(
            json.dumps({
                "total_ms": round(cursor_ms),
                "text_fingerprint": plan.get("text_fingerprint"),
                "segments": timing,
            }),
            encoding="utf-8",
        )
        return opus, timing_path


class Cancelled(Exception):
    """The owner stopped this job while it was rendering."""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True, help="e.g. https://manhwamaniacs.xyz/api")
    ap.add_argument("--token", default=os.getenv("MM_RENDER_WORKER_TOKEN", ""))
    ap.add_argument("--pack", required=True)
    ap.add_argument("--model-dir", default=r"D:\models\IndexTTS-2.5")
    ap.add_argument("--work", default=r"D:\models\render-work")
    ap.add_argument("--worker-id", default=None)
    ap.add_argument("--fraction", type=float, default=0.30)
    ap.add_argument("--once", action="store_true", help="one job, then exit")
    args = ap.parse_args()

    if not args.token:
        print("no token: set MM_RENDER_WORKER_TOKEN or pass --token")
        return 2

    worker_id = args.worker_id or f"{socket.gethostname()}-{os.getpid()}"
    server = Server(args.server, args.token, worker_id)
    pack = Path(args.pack)
    work = Path(args.work)
    renderer: Renderer | None = None

    print(f"worker {worker_id} against {args.server}", flush=True)

    while True:
        # A PAUSE file is the hand brake: touch it and the box stops taking
        # work without anybody having to kill a process mid-chapter.
        if (pack.parent / "RENDER_PAUSE").exists():
            time.sleep(IDLE_SLEEP)
            continue

        free = free_vram_mb()
        if free is None or free < CLAIM_FLOOR_MB:
            time.sleep(IDLE_SLEEP)
            continue

        try:
            job = server.claim()
        except urllib.error.URLError as exc:
            print(f"claim failed: {exc}", flush=True)
            time.sleep(IDLE_SLEEP)
            continue
        if not job:
            time.sleep(IDLE_SLEEP)
            if args.once:
                return 0
            continue

        job_id = job["job_id"]
        plan = job["plan"]
        plan["text_fingerprint"] = job.get("text_fingerprint")
        total = len(plan["segments"])
        print(f"claimed {job['chapter_key']}: {total} segments", flush=True)

        out_dir = work / job_id
        out_dir.mkdir(parents=True, exist_ok=True)
        last_beat = [time.time()]

        def on_segment(done: int) -> bool:
            """Heartbeat, and answer whether to keep going."""
            now = free_vram_mb()
            if now is not None and now < RELEASE_FLOOR_MB:
                raise Yielded()
            if time.time() - last_beat[0] < HEARTBEAT_EVERY:
                return True
            last_beat[0] = time.time()
            try:
                state = server.heartbeat(job_id, done)
            except urllib.error.URLError:
                # A blip must not throw away nine minutes of work. The lease
                # outlives a short outage; if it does not, the upload fails
                # and the server puts the job back.
                return True
            return not (state or {}).get("cancelled")

        try:
            if renderer is None:
                renderer = Renderer(args.model_dir, pack, args.fraction)
            audio, timing = renderer.render(plan, out_dir, on_segment)
            server.complete(job_id, audio, timing)
            print(f"done {job['chapter_key']}", flush=True)
        except Cancelled:
            print(f"cancelled {job['chapter_key']}", flush=True)
        except Yielded:
            server.release(job_id, "gpu wanted by another process")
            print("released: the card is busy", flush=True)
            time.sleep(IDLE_SLEEP)
        except KeyError as exc:
            server.fail(job_id, "voice_missing", str(exc), retryable=False)
        except Exception as exc:  # noqa: BLE001 - the loop must survive anything
            server.fail(job_id, type(exc).__name__, str(exc), retryable=True)
            print(f"failed {job['chapter_key']}: {exc}", flush=True)
        finally:
            _clean(out_dir)

        if args.once:
            return 0


class Yielded(Exception):
    """The card is wanted by something with more invested than a chapter."""


def _clean(path: Path) -> None:
    import shutil

    try:
        shutil.rmtree(path, ignore_errors=True)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
