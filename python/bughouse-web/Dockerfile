# Build from repository root:
# podman build -f python/bughouse-web/Dockerfile -t bughouse-web .
FROM docker.io/library/node:22-bookworm-slim AS frontend
WORKDIR /web
COPY python/twic-position-finder/frontend/package*.json ./
RUN npm ci --no-audit --no-fund
COPY python/twic-position-finder/frontend/ ./
# The standalone container serves its own API. Cloudflare Pages builds can
# instead set this to the HTTPS engine-service origin.
ENV PUBLIC_BUGHOUSE_API_URL=""
RUN npm run build

FROM docker.io/library/python:3.12-slim-bookworm AS assets
WORKDIR /app
COPY tools/fetch_bughouse.py tools/bughouse.lock.json ./tools/
# Downloads are SHA-256 checked against the repository's pinned lockfile.
RUN python tools/fetch_bughouse.py --only bughouse-linux
RUN mkdir -p /engine && python -c "import gzip,pathlib; [(pathlib.Path('/engine')/p.stem).write_bytes(gzip.decompress(p.read_bytes())) for p in pathlib.Path('assets/bughouse').glob('*.gz')]"
RUN chmod 755 /engine/hivemind-linux

FROM docker.io/library/python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 tini && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY python/bughouse-web/requirements.txt /app/python/bughouse-web/requirements.txt
RUN pip install --no-cache-dir -r /app/python/bughouse-web/requirements.txt
COPY tools/mcp/bughouse /app/tools/mcp/bughouse
COPY python/bughouse-web/server.py python/bughouse-web/worker.py /app/python/bughouse-web/
COPY assets/licenses/HIVEMIND_LICENSE.txt assets/licenses/ONNXRUNTIME_LICENSE.txt assets/licenses/ONNXRUNTIME_THIRD_PARTY_NOTICES.txt /app/licenses/
COPY LICENSE /app/licenses/CHESS_AUTO_PREP_LICENSE.txt
COPY --from=assets /engine /app/engine
COPY --from=frontend /web/dist /app/site
RUN useradd --uid 10001 --create-home bughouse
USER 10001
ENV HIVEMIND_BIN=/app/engine/hivemind-linux \
    HIVEMIND_MODEL=/app/engine/hivemind.onnx \
    HIVEMIND_LIB=/app/engine \
    BUGHOUSE_STATIC_DIR=/app/site \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD python -c "import json,urllib.request; assert json.load(urllib.request.urlopen('http://127.0.0.1:8080/api/bughouse/health'))['engine_installed']"
ENTRYPOINT ["/usr/bin/tini", "--"]
# Never add multiple workers: the admission gate is process-local.
CMD ["uvicorn", "server:app", "--app-dir", "/app/python/bughouse-web", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--limit-concurrency", "32", "--timeout-keep-alive", "5", "--no-proxy-headers"]
