# Bughouse Lab in the browser

The existing Astro website now has `/bughouse`. Visitors move on either
board, drop from reserves, load a move sequence or dual FEN, undo, and ask
Hivemind for a joint move. Both desktop and phone layouts work. No account,
desktop installation or engine download is needed by the visitor.

This directory is the independent Linux HTTP service that makes the page
work. It imports the existing `tools/mcp/bughouse` rules and analysis client;
it does not launch Flutter or read game databases. Positions are submitted to
the service, held for the request, and not persisted. The first version is
an analysis board, not a four-player game server with clocks or matchmaking.

## Hosting decision

Use **the existing static site plus a CPU service** first:

```
chessautoprep.com/bughouse  ──HTTPS──▶ api.chessautoprep.com/api/bughouse/*
                                      nginx → Bughouse API → Hivemind + ONNX
andrewbernal.com           ──link───▶ chessautoprep.com/bughouse
```

The existing TWIC API remains on port 8000. Bughouse runs independently on
8080; proxy only `/api/bughouse/` to it. One service can also host the bundled
website at `/bughouse/`, so a dedicated subdomain such as
`bughouse.andrewbernal.com` works without copying the feature to another repo.
The actual public address still depends on deploying the service and routing
the chosen domain. Source integration does not deploy either website.

Why this architecture:

* Both existing websites are Astro static sites on Cloudflare Pages. The
  engine is a native C++ executable with a ~54 MB ONNX network, subprocess
  protocol, and MCTS search. An ordinary static deployment cannot run it.
* A small Linux x86-64 CPU service uses the engine already shipped in the app.
  The supplied configuration starts with two CPUs, 2 GiB RAM and one search
  at a time. These are initial resource bounds, not a traffic guarantee;
  measure throughput on the actual host before widening public access.
* A fully local browser engine is a possible second phase. ONNX Runtime Web
  supports browser inference, but loading the network alone does not port
  Hivemind's two-board rules, MCTS, joint actions, threading and UCI driver.
  That requires a WASM build of the search/rules with a browser inference
  bridge, operator checks, and desktop/mobile benchmarks. It is a separate
  engine port, not a Flutter web build flag.

References: [ONNX Runtime Web](https://onnxruntime.ai/docs/tutorials/web/),
[Cloudflare runtime compatibility](https://developers.cloudflare.com/workers/runtime-apis/nodejs/),
[FastAPI container deployment](https://fastapi.tiangolo.com/deployment/docker/).

## Run locally

From the repository root (Python 3.11+; production targets Linux):

```sh
python3 -m venv python/bughouse-web/.venv
python/bughouse-web/.venv/bin/pip install -r python/bughouse-web/requirements.txt
python3 tools/fetch_bughouse.py --only bughouse-linux
scripts/ci.sh with -- python/bughouse-web/.venv/bin/uvicorn server:app \
  --app-dir python/bughouse-web --host 127.0.0.1 --port 8080 --workers 1
```

In a separate terminal, the normal frontend development command is:

```sh
cd python/twic-position-finder/frontend
PUBLIC_BUGHOUSE_API_URL=http://127.0.0.1:8080 npm run dev
```

For this two-origin development setup, add `http://localhost:4321` (or the
actual Astro origin) to `BUGHOUSE_ORIGINS` **before starting Uvicorn**. The
automatic browser check below uses one origin, a random loopback port, and
tears down both Chrome and Uvicorn itself. Stop previews before starting
another bounded check on the same worktree.

## Deploy on a Linux VPS

Deploy the **engine before the frontend**, so the new public page has a
working API immediately. Existing hosting credentials/server access and the
chosen DNS entry are required; there are no credentials in this directory.

1. Copy/clone this repository revision onto the server. Install Docker with
   Compose. The image fetches the engine/model and verifies their pinned
   SHA-256 hashes using `tools/bughouse.lock.json`; no desktop assets need to
   be uploaded. It includes Hivemind and ONNX Runtime notices.
2. Start the service:

   ```sh
   cd python/bughouse-web
   docker compose up --build -d
   curl --fail http://127.0.0.1:8080/api/bughouse/health
   curl --fail http://127.0.0.1:8080/api/bughouse/analyse \
     -H 'Content-Type: application/json' \
     -d '{"movetime_ms":250,"multipv":1}'
   ```

   Health checks report configuration/liveness, not a neural-network probe;
   the second request verifies the installed engine really searches.
   Compose uses host networking **on Linux**, binds only `127.0.0.1`, and
   trusts forwarded addresses only from the loopback nginx connection. It
   limits CPU, memory and process count and runs unprivileged/read-only.
   Never expose that proxy-trusting listener directly to the internet or
   set `--forwarded-allow-ips='*'`. The bare image defaults to ignoring proxy
   headers for environments that do expose its HTTP listener directly.
3. Add the `limit_req_zone` and location from
   [`nginx.conf.example`](nginx.conf.example) to the existing HTTPS nginx
   configuration. Check `nginx -t`, then reload nginx. Test the same two
   requests through `https://api.chessautoprep.com`. Keep its existing TLS
   certificate and TWIC upstream configuration.
4. Build/deploy the Astro frontend with
   `PUBLIC_BUGHOUSE_API_URL=https://api.chessautoprep.com` (already the
   default). Publish its `dist/` through the existing Cloudflare Pages
   project. Verify `/bughouse`, make a move and run an analysis in the public
   browser. Link that page from andrewbernal.com when desired.

For a **standalone subdomain**, point its DNS at the engine host and configure
an HTTPS reverse proxy for `/` to the service instead. The image already
includes the static website and builds the bughouse client with a same-origin
API. Redirect the subdomain's `/` to `/bughouse/` if desired. `BUGHOUSE_ORIGINS`
only needs changes for *cross-origin* frontends; a same-origin page works
without CORS. The rest of the bundled website still links to the normal
TWIC API and is not a new deployment of that API.

The image can also be built with Podman from the root:

```sh
scripts/ci.sh with -- podman build --isolation=chroot --jobs=1 \
  --ignorefile python/bughouse-web/Dockerfile.dockerignore \
  -f python/bughouse-web/Dockerfile -t localhost/chess-prep-bughouse:dev .
```

The explicit ignorefile is for Podman compatibility; Docker discovers the
Dockerfile-specific ignorefile automatically. It excludes private `.env`
files, local databases, dependencies and desktop data from the build context.
Publish the corresponding source revision with the deployment and keep the
website's Source link pointing to that revision (the project is AGPL-3.0).

## HTTP contract and capacity

| Endpoint | Purpose |
| --- | --- |
| `GET /api/bughouse/health` | Liveness, whether engine files exist, busy flag, maximum budget; no engine process is started |
| `POST /api/bughouse/position` | Validated boards, canonical dual FEN, pieces, pockets, legal SAN/UCI moves, history |
| `POST /api/bughouse/analyse` | Actual joint suggestions and calibrated advantage, using two searches |

Position input: `dual_fen` (optional, max 1,024 chars), `moves` (up to 256
tagged SAN/UCI strings), and `team` (`white` or `black`, colour on board A).
Analysis adds `movetime_ms` (250–3,000 per team, default 1,500), `multipv`
(1–3), `time_advantage` (boolean), and `require_move_on` (`none`, `A`, `B`).
Extra fields, invalid types and unsafe/illegal positions return 422. Clients
cannot provide a binary/model path, arbitrary UCI options or unbounded nodes.
Only canonical FEN enters the engine protocol.

One Uvicorn worker admits one analysis at a time, with **no waiting queue**.
Overlapping requests return 429 with `Retry-After: 5`. Per-client limits are
six analysis requests and 180 position requests per minute, including failed
attempts that passed schema validation. State is memory-bounded to 4,096
clients per limiter; request bodies are capped at 16 KiB, including chunked
bodies, and must arrive within ten seconds. Analysis kills/reaps its worker
and engine process group after 35 seconds, on cancellation, and after normal
completion; engine errors return a generic 503, timeouts 504. Detailed startup
errors are retained only in server logs. Proxy access logs contain URLs and
client addresses, not position bodies.

Each request uses a fresh engine to isolate visitors and guarantee that no
permanent-brain work survives. Startup overhead is included in the 35-second
deadline. There is no durable queue, cache, automatic retry, multi-worker
coordination or authentication in this first version. Keep one ASGI worker
and one replica; adding workers bypasses the process-local admission gate.
For larger audiences, introduce a shared queue/cache and measured worker
capacity before increasing replica count. The CPU/memory bounds prevent
unbounded compute, but the service can still be busy for legitimate visitors.

The UI displays calibrated `advantage` only when calibration is measured,
and otherwise reports that no estimate is available. It never labels raw
Hivemind scores as Stockfish pawns or presents `win_percent` as an empirical
probability. No legal moves is not automatically match over: a partner can
still send a piece, and no real clocks are modeled here.

## Verification

Install `httpx` in the Python environment for API tests; browser checks use
the frontend's existing `puppeteer-core` dependency and local Chrome
(`CHROME_BIN` can select its executable).

```sh
scripts/ci.sh with -- python3 python/bughouse-web/test_server.py
scripts/ci.sh with -- python3 python/bughouse-web/test_server.py --engine
scripts/ci.sh with -- python3 python/bughouse-web/check_browser.py
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend exec -- \
  astro check --root python/twic-position-finder/frontend
scripts/ci.sh analyze lint
```

The browser test builds with a same-origin API and uses actual Hivemind for
analysis/play. It covers capture transfer, reserve drops, undo, flip, invalid
FEN recovery, underpromotion, busy handling and phone overflow. Screenshots
and the preview log are in ignored `build/bughouse-web/`. Rebuild with the
production API origin before publishing an independently hosted frontend;
the test's `dist/` expects to be served alongside its API.
