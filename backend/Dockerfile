# ManhwaManiacs backend — FastAPI on uvicorn (:8000), non-root.
# This container is internal-only: the frontend proxies /api/* to it over the
# per-environment private compose network. Persistent state is only the metadata
# SQLite DB + settings.json on the mounted /data volume (via MM_DB_PATH /
# MM_SETTINGS_PATH) so it survives image rebuilds. Chapter images are never
# stored server-side — clients download them through the source image proxy.

FROM python:3.13-slim AS run
WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# No system dependencies: everything ships as manylinux wheels (curl_cffi
# bundles its own libcurl, av its own libav* for the iOS narration m4a).
# OCR now runs on the client, not the server.
COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY . .

# Non-root, with a writable data dir for the metadata DB + settings.json.
RUN useradd -u 1000 -m app \
    && mkdir -p /data \
    && chown -R app:app /data /app
USER app

ENV MM_DB_PATH=/data/manhwamaniacs.db \
    MM_SETTINGS_PATH=/data/settings.json

EXPOSE 8000
CMD ["python", "main.py"]
