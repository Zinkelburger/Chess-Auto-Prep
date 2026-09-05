# Standalone Pure expectimax builder

Both this C program and the Flutter app follow [the same Pure contract](../docs/ALGORITHM.md).
The C program is also what the chess-prep MCP expectimax tools launch.

Pure searches every legal candidate within the explicit engine-loss constraint
and every positive-probability opponent reply. No novelty/setup bonuses, MultiPV
caps, probability cutoffs, or separate deep-verification promise.

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

Start small: branching is exponential. A four-ply tree can still be expensive.

```
./bin/tree_builder -c w -d 4 -e 16 --max-eval-loss 50 \
  --maia-model /path/to/maia3_simplified.onnx -S /path/to/stockfish output
```

Master targeting is on by default: Lichess master-game frequencies in book,
Maia off-book. Add `--maia-only` to use Maia throughout. `--maia-elo` controls
the predicted opponent rating. The app's local book is a different data source.

Output includes `output.pgn`, `output.tree.json`, and the cache database.
`--resume` continues a compatible saved Pure tree. Change engine depth, safety
limit, opponent model, or root by starting a new build. Legacy trees remain
readable but cannot be resumed as Pure. An interrupted search is incomplete;
its current move ordering is provisional and its value bounds are reported.

`make test-pure` checks production backup against the shared independently
solved fixtures and runs the builder against a deterministic UCI oracle. It
also works with `NO_MAIA=1`. The Makefile tracks header dependencies and build
flags, so switching between Maia-enabled and offline builds recompiles objects.

## License

AGPL-3.0 — see main project [LICENSE](../LICENSE) file.
