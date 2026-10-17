# Static Hivemind build

This folder builds Hivemind, the bughouse engine, to run **entirely in a
visitor's browser**: a WebAssembly build of the engine with its network on
ONNX Runtime Web, on the GPU through WebGPU or on CPU threads, searching one
board with the partner board held still. No page of the website loads it:
the site's `/bughouse` board runs Lichess's crazyhouse Fairy-Stockfish (see
the [frontend guide](../../python/twic-position-finder/frontend/README.md#bughouse-board)).
`prepare_assets.py` runs on every frontend build, because the ONNX Runtime it
copies also serves the Expectimax tab's Maia.

## Deploy on Cloudflare Pages

Use the existing Chess Auto Prep Pages project:

| Setting | Value |
| --- | --- |
| Root directory | `python/twic-position-finder/frontend` |
| Build command | `npm run build` |
| Output directory | `dist` |
| Build environment | Node 22.12+ and Python 3.11+ (standard Pages build environment) |
| Bughouse environment variables / bindings | None |

The `prebuild` step runs the puzzle, prep and analysis tests and the Astro
type check, then `prepare_assets.py` and `tools/prepare_prep_web.py`.
`prepare_assets.py` checks the committed engine against
`public/bughouse-engine/build.json` (a stale binary fails the build),
downloads the checksum-pinned Hivemind network (`tools/assets.lock.json`)
unless `assets/bughouse/hivemind.onnx.gz` already matches, splits its gzip
bytes into 16 MiB parts and copies ONNX Runtime Web from the pinned npm
dependency: the WebGPU (`.jsep`) build for Hivemind and the plain build for
the Expectimax tab's Maia. It writes `model.json` with every part's checksum,
the runtime's and the uncompressed model's, and copies the Hivemind, ONNX
Runtime and app licences beside them. The build fails if any engine asset is
at or above Pages' 25 MiB file limit.

The compressed network is about 32 MB; with the WebGPU runtime (about 22 MB)
the first download is about 55 MB. The page downloads both itself, verifies
them against `model.json` and keeps them in Cache Storage.

The small compiled Hivemind module and its source archive are committed. Pages
does **not** compile C++, install Emscripten, run Python after deployment, or
start an engine process. Python is only a static asset preparation step during
the build.

Once deployed, use `https://chessautoprep.com/bughouse/`. To host it under a
separate subdomain instead, upload the same `dist/` output to a second Pages
project with that custom domain and visit its `/bughouse/` path. Do not copy
these files over another website's root: the build includes the other Chess
Auto Prep pages.

Local build/preview:

```sh
cd python/twic-position-finder/frontend
npm ci
npm run build
npm run preview
```

## Engine port

`CMakeLists.txt` compiles the pinned Hivemind source revision
`5508ba9daf4164e48a8a8a9b39e101efdc60e97a`, with `patches/*.patch` applied
in name order, plus three browser adapters. `patches/frozen-board.patch` adds
`g_frozenBoardB`: board B gets no moves, a check on A that a drop could block
lets the checked side drop the blocker it waits for (a pawn, or a knight where
a pawn cannot stand), nobody sits (nothing would arrive), the sit plane says
which team is up on the clock as Hivemind's `TimeAdvantage` gives it
(`g_frozenRootMaySit`: the root team's, the other team the opposite), and
`g_frozenValueOffset` is subtracted from every network value. With the flag off searches are unchanged.

* `bridge.cc`: the validated position interface and the searches, over the
  engine's own `Board`, `SearchThread` and `Node`.
  `bh_frozen_search(fen, whiteMaySit, nodes, millisCap, lines, reportMs, batch, keep)` is
  the one-board search. It searches one board's FEN (hands in brackets) for
  the side to move. Board B is the starting position held still, the
  opponent's colour to move there, with every piece missing from A in the
  pocket of whoever captured it (bughouse conserves pieces; without them the
  network barely notices a missing queen). Two static inferences first
  measure the two seats' shared offset under one clock (`whiteMaySit`: White
  up on the clock, else Black); the search subtracts it, so q is a winning
  chance from the side to move with the clock's worth in it (a level opening
  is clearly winning for the side up on the clock). It stops at
  the node budget (up to 1,000,000), the time cap, a solved root or Stop,
  reports to `Module.onFrozenReport` every `reportMs` and returns up to five
  lines with board A's moves only. `batch` (1 to 64) leaves are evaluated
  together: 32 on a GPU, 1 on the CPU. With `keep`, the search keeps its
  tree, and a later `keep` search of the same FEN and clock carries on from it: node
  count and depth continue, and `resumed_nodes` says how many came from
  before.
  The module also exports `bh_position` (both boards' FENs and legal moves
  after a move list; `test_rules.py` uses it) and the two-board searches
  `bh_search`, `bh_search_nodes` and `bh_values`, which the page does not call.
* `engine_web.cc`: replaces native ONNX Runtime with an Asyncify call to
  ONNX Runtime Web, keeping the engine's plane encoder and neural outputs.
* `thread_web.cc`: supplies Fairy-Stockfish's thread-local counters without
  starting an OS thread. The browser worker already isolates the engine.

The frontend's `src/analysis/hivemind.worker.ts` loads the module, prepares
the model, feeds 74×8×8 input tensors to the network, and copies value,
policy, WDL and moves-left outputs back to the C++ search. It yields between
evaluations so Stop can be processed. The web search shares the engine's MCTS
and terminal logic but not the desktop agent's separate root mate-search
helper, background pondering or shared transposition table, so results and
speed can differ from the native engine. Raw Hivemind values are not
Stockfish pawn scores or measured win probabilities.

## Rebuild the WebAssembly module

This is only needed when changing the C++ bridge, the patches or the pinned
engine source. Install/activate Emscripten SDK **4.0.15**, then from the
repository root:

```sh
scripts/ci.sh with -- python3 tools/bughouse_web/build.py --emsdk /path/to/emsdk
```

The script checks out the pinned Hivemind revision under ignored `build/`,
exports it to `build/bughouse-web-patched/` and applies `patches/*.patch`.
`--source /path/to/hivemind` can reuse an existing clean checkout at that
revision; it never edits that checkout. `public/bughouse-engine/build.json`
records the source revision, compiler version, bridge hashes and output
hashes. The normal site build verifies these hashes and rejects stale binaries.
Commit the `.mjs`, `.wasm`, source archive and build metadata together with
bridge changes. Model and ONNX runtime assets are ignored and recreated by
`prepare_assets.py` during `npm run build` or `npm run dev`.

Upstream Fairy-Stockfish code is GPL-3.0; the app is AGPL-3.0. The published
engine directory carries `hivemind-source.tar.gz`, containing the exact engine
source, browser adapters, licences and compilation instructions, beside the
Hivemind, ONNX Runtime and app licences.

## Verification

```sh
scripts/ci.sh with -- python3 tools/bughouse_web/test_rules.py
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run test:analysis
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run build
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run test:bughouse:browser
```

The rules check compares 251 two-board positions from the compiled module
against the python-chess bughouse model, including cross-board captures,
drops, en passant, castling, every promotion and promoted captures, and checks
that invalid input is rejected without corrupting the reusable module. It
needs the development `python-chess` dependency, already used by the bughouse
MCP server. The browser check is described in the
[frontend guide](../../python/twic-position-finder/frontend/README.md#checks).

References: [Pages asset limits](https://developers.cloudflare.com/pages/platform/limits/),
[Emscripten Asyncify](https://emscripten.org/docs/porting/asyncify.html),
[ONNX Runtime Web deployment](https://onnxruntime.ai/docs/tutorials/web/deploy.html),
[pinned engine source](https://github.com/Zinkelburger/hivemind/tree/5508ba9daf4164e48a8a8a9b39e101efdc60e97a).
