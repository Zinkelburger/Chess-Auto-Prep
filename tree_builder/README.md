> Stockfish expectimax (Pure and Fast) uses **Maia throughout**. Master
> and Lichess flags apply only to separate database build modes; old settings
> cannot re-enable master replies. Start a new build for an old master-based
> tree. Maia must be available; there is no database fallback.

# Standalone expectimax builder

This C program implements [the Pure expectimax contract](../docs/ALGORITHM.md).
The app's search (`lib/chess/generation/search.dart`) uses the same recurrence
and v4 tree format, with a narrower interactive candidate policy.
It is what the chess-prep MCP expectimax tools launch.

Pure searches every legal candidate within the explicit engine-loss constraint
and every positive-probability opponent reply. No novelty/setup bonuses, MultiPV
caps, probability cutoffs, or separate deep-verification promise. The app's
opponent-reply cut is opt-in: `--reply-mass 0.9 --max-replies 5` keeps the
likeliest replies to 90% of Maia's distribution, at most five, renormalized
(the chess-prep MCP passes these by default). A saved tree records its cut and
resumes only with it.

## Requirements

- GCC or Clang compiler
- libcurl development files
- ONNX Runtime library (for Maia neural network inference)
- Stockfish binary (required for building)

### Fedora
```bash
sudo dnf install gcc make libcurl-devel onnxruntime-devel
```

### Ubuntu/Debian
```bash
sudo apt install build-essential libcurl4-openssl-dev libonnxruntime-dev
```

### macOS
```bash
brew install curl onnxruntime
```

**Note**: If ONNX Runtime is not available via package manager, download the appropriate release from [Microsoft's ONNX Runtime releases](https://github.com/microsoft/onnxruntime/releases) and extract to a location where the linker can find it (e.g., `/usr/local/lib`).

## Building

```bash
cd tree_builder
make
```

The executable will be at `bin/tree_builder`.

## Usage

Pure is the default. Add `--search fast` (alias `rolling`) for approximate
repeated four-ply lookahead: commit our next move, retain every modeled
opponent reply, and repeat. Only this builder and the MCP that launches it have
Fast; the app reads only Pure trees. See
[Fast search](../docs/ALGORITHM.md#fast-search-c-builder-and-mcp-only).

Start small: branching is exponential. A four-ply tree can still be expensive.

```
./bin/tree_builder -c w -d 4 -e 16 --max-eval-loss 50 \
  --maia-model /path/to/maia3_simplified.onnx -S /path/to/stockfish output
```

Stockfish expectimax (the default `--build-mode`) uses Maia for every
opponent position; `--maia-model` is required. `-m`/`--masters` and `--lichess`
apply only to the database build modes and cannot switch expectimax off Maia,
including when `--resume` restores them. `--maia-elo` sets the predicted
opponent rating (default 2200). Defaults: `-d 4`, `-e 16`, `--max-eval-loss 50`.

Output includes `output.pgn`, `output.tree.json`, and the cache database.
Running again with the same name continues `output.tree.json`; `--resume`
additionally restores the earlier run's flags from `output.db`. A continued
tree keeps its root, side, engine depth, loss limit, Maia rating, search method
and reply cut, and its horizon may only grow; change any of those by starting a
new build. Heuristic trees from earlier builder versions remain readable but
cannot be resumed as Pure. An interrupted search is incomplete;
its current move ordering is provisional and its value bounds are reported.

`make test-pure` checks production backup against the shared independently
solved fixtures and runs the builder against a deterministic UCI oracle. It
also works with `NO_MAIA=1`. The Makefile tracks header dependencies and build
flags, so switching between Maia-enabled and offline builds recompiles objects.

## License

AGPL-3.0 — see main project [LICENSE](../LICENSE) file.
