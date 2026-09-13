# Static Bughouse Lab

`/bughouse` runs **entirely in the visitor's browser**. Cloudflare Pages only
serves static files. There is no analysis API, paid compute service, Pages
Function, R2 bucket, database or account. Positions are never uploaded.

The page supports both boards, captures sent to the partner's reserve, legal
drops, promotions, undo, board flipping, SAN/UCI move sequences, dual FEN,
joint Hivemind recommendations, clock-advantage/required-board settings and
Stop. It is an analysis tool, not a four-player online game with live clocks.

## Deploy on Cloudflare Pages

Use the existing Chess Auto Prep Pages project:

| Setting | Value |
| --- | --- |
| Root directory | `python/twic-position-finder/frontend` |
| Build command | `npm run build` |
| Output directory | `dist` |
| Build environment | Node 22.12+ and Python 3.11+ (standard Pages build environment) |
| Bughouse environment variables / bindings | None |

The `prebuild` step downloads the existing checksum-pinned Hivemind network,
splits its gzip bytes into two files smaller than 25 MiB, and copies the ONNX
Runtime Web files from the pinned npm dependency. The compressed network is
about 32 MB; the complete initial engine download is about 44 MB. The browser
verifies the chunks and uncompressed model, assembles them in memory, and
caches model chunks when Cache Storage is available. No special headers or
cross-origin isolation are necessary: both the engine and inference are
single-threaded inside a Web Worker.

The small compiled Hivemind module and its source archive are committed. Pages does **not** compile
C++, install Emscripten, run Python after deployment, or start an engine
process. Python is only a static asset preparation step during the build.
The build fails if any engine asset is at or above Pages' 25 MiB file limit.

Once deployed, use `https://chessautoprep.com/bughouse/`. Andrewbernal.com can
link there. To host this under a separate subdomain instead, the exact same
`dist/` output can be uploaded to a second Pages project with that custom
domain; visit its `/bughouse/` path. Do not copy these files over the personal
website's existing root: the build includes the other Chess Auto Prep pages.
The Bughouse feature is static even though the unrelated TWIC alerts feature
still uses its existing API.

Local build/preview:

```sh
cd python/twic-position-finder/frontend
npm ci
npm run build
npm run preview
```

After engine assets have loaded, an open page can continue moving and
analysing with networking disabled. This is not a promise that a closed page
can be reopened offline: there is no page-caching service worker.

## Engine port

`CMakeLists.txt` compiles the pinned Hivemind source revision
`5508ba9daf4164e48a8a8a9b39e101efdc60e97a` plus three browser adapters:

* `bridge.cc`: validated position/SAN/UCI interface and bounded MCTS searches.
  It uses the existing `Board`, `SearchThread` and `Node` implementations.
* `engine_web.cc`: replaces native ONNX Runtime with an Asyncify call to
  ONNX Runtime Web, keeping the existing plane encoder and neural outputs.
* `thread_web.cc`: supplies Fairy-Stockfish's thread-local counters without
  starting an OS thread. The browser worker already isolates the engine.

The frontend's `engine.worker.ts` loads the module, prepares the model, feeds
74×8×8 input tensors to the same network, and copies value, policy, WDL and
moves-left outputs back to the C++ search. It yields between evaluations so
Stop can be processed. All HTTP traffic is static GETs; move/analysis
requests are local worker messages.

The web search uses batch size one, one worker and a 10,000-node cap. It
shares the engine's MCTS and terminal logic, but does not run the desktop
agent's separate root mate-search helper, background pondering or shared
transposition table. Results and speed can differ from the native app;
search strength depends on the visitor's device and chosen time budget.
The UI offers 3, 10 or 30 seconds per team, plus model initialization time.
Stop finishes the current inference rather than terminating the worker and
throwing away the loaded model.

Advantage is `(q_ours - q_theirs) / 2`, using two searches at the same budget.
It is displayed only when both teams have usable evaluations; otherwise the
page shows suggestions without an estimate. Raw Hivemind values are not
Stockfish pawn scores or measured win probabilities. With no live clocks,
having no legal move does not automatically declare the match over: a
partner may still deliver a rescue piece.

## Rebuild the WebAssembly module

This is only needed when changing the C++ bridge or pinned engine source.
Install/activate Emscripten SDK **4.0.15**, then from the repository root:

```sh
scripts/ci.sh with -- python3 tools/bughouse_web/build.py --emsdk /path/to/emsdk
```

The script checks out the pinned Hivemind revision under ignored `build/`.
`--source /path/to/hivemind` can reuse an existing clean checkout at that
revision; it never edits that checkout. `public/bughouse-engine/build.json`
records the source revision, compiler version, bridge hashes and output
hashes. The normal site build verifies these hashes and rejects stale binaries.
Commit the `.mjs`, `.wasm`, source archive and build metadata together with bridge
changes. Model and ONNX runtime assets are ignored and recreated by
`prepare_assets.py` during `npm run build` or `npm run dev`.

Hivemind notices, ONNX Runtime notices and the app license are copied into
the published engine directory. Upstream Fairy-Stockfish code is GPL-3.0;
the app is AGPL-3.0. The page links to `hivemind-source.tar.gz`, containing the
exact engine source, browser adapters, licenses and compilation instructions.

## Verification

```sh
scripts/ci.sh with -- python3 tools/bughouse_web/test_rules.py
scripts/ci.sh with -- python3 tools/bughouse_web/check_browser.py
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend exec -- \
  astro check --root python/twic-position-finder/frontend
scripts/ci.sh analyze lint
```

The rules check compares 251 two-board positions against the existing
python-chess bughouse model, including en passant, castling, every promotion,
promoted captures and invalid input recovery. It needs the development
`python-chess` dependency, already used by the bughouse MCP server.

The browser check uses a **plain Python static file server**, Chrome via the
existing `puppeteer-core` dependency (`CHROME_BIN` selects the executable),
and the real WASM engine/neural model. It tests moves, cross-board capture
and drops, undo, promotion, invalid input, real recommendations/play,
download failure/retry, cancellation/recovery, phone layout and analysis with all networking off.
It fails if the page makes an API request or sends any POST. The server and
browser are closed afterward. Screenshots go to ignored
`build/bughouse-web/` for visual inspection.

The final clean install/build, Astro check, browser check, rules comparison,
and repository `analyze lint` checks passed. Browser verification used desktop
Chrome and a phone-sized viewport, not physical iOS/Android devices.

The clean install's npm audit reports 11 findings (one critical, nine high,
one low) in the site's existing Astro/build dependency tree. All 11 affected
package versions are unchanged from the starting checkout; none is in the
new ONNX dependency tree. Updating the existing site's build dependencies
remains separate maintenance. This build deploys static HTML/JS, without an
Astro server or development server.

References: [Pages asset limits](https://developers.cloudflare.com/pages/platform/limits/),
[Emscripten Asyncify](https://emscripten.org/docs/porting/asyncify.html),
[ONNX Runtime Web deployment](https://onnxruntime.ai/docs/tutorials/web/deploy.html),
[pinned engine source](https://github.com/Zinkelburger/hivemind/tree/5508ba9daf4164e48a8a8a9b39e101efdc60e97a).
