# Chess Opening Tree Builder

A C CLI tool that builds chess opening repertoires by interleaving a
human-move source (pure Maia by default, or pure Lichess with `--lichess`)
with Stockfish evaluation. Branches are pruned inline by the eval window,
producing a focused repertoire tree with evaluations on every node.

## Architecture

**Single interleaved DFS** — no separate build/eval/discovery stages:

- **Our-move nodes**: Stockfish MultiPV (constant count at every depth) →
  eval-loss filter → (optional Lichess enrichment for SAN/win rates)
- **Opponent-move nodes**: one source only — pure Maia (default) OR pure
  Lichess (`--lichess`). Probabilities are kept raw; the missing mass is
  accounted for by an eval-based tail term during expectimax.
- **No depth-based tapering** — branching budgets (`our_multipv`,
  `opp_mass_target`, `opp_max_children`) are constant at every ply.
  Tapering would silently bias the MAX/CHANCE operators; depth pruning
  is instead handled by `min_probability`, `max_depth`, and the eval
  window.
- **Eval-window pruning** at every node — stop exploring when positions
  leave `[min_eval, max_eval]`
- **All evals cached** in SQLite for instant resume

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

```bash
./bin/tree_builder [options] <name>
```

The `<name>` argument is the base name for all output files:

| File | Purpose |
|------|---------|
| `<name>.pgn` | Repertoire lines (primary output) |
| `<name>.tree.json` | Tree state for resumption |
| `<name>.db` | Cached evals and explorer data |

### Core Options

| Option | Description | Default |
|--------|-------------|---------|
| `-f, --fen <FEN>` | Starting position FEN | Standard starting position |
| `-c, --color <w\|b>` | Play as white or black | required |
| `-p, --probability <P>` | Min probability threshold | 0.0001 (0.01%) |
| `-d, --ply <N>` | Max tree depth in ply (half-moves) | 20 |
| `-e, --eval-depth <N>` | Stockfish search depth | 20 |
| `-t, --threads <N>` | Parallel Stockfish engines | 4 |
| `-S, --stockfish <path>` | Stockfish binary path | auto-detect |
| `-n, --name <name>` | Repertoire name (shown in PGN headers) | |
| `-v, --verbose` | Verbose progress | |

### Our-Move Candidates (Engine-Driven)

| Option | Description | Default |
|--------|-------------|---------|
| `--our-multipv <N>` | MultiPV count at every depth (constant) | 5 |
| `--max-eval-loss <cp>` | Skip candidates worse than best by this | 50 |

### Opponent Responses (single source — Maia OR Lichess)

| Option | Description | Default |
|--------|-------------|---------|
| `--opp-max-children <N>` | Max opponent responses | 6 |
| `--opp-mass <0-1>` | Mass target at every depth (constant) | 0.95 |
| `--maia-only` | Pure Maia for opponent moves (no Lichess) | on |
| `--lichess` | Pure Lichess for opponent moves (no Maia) | off |
| `-g, --min-games <N>` | Min games per move (Lichess) | 10 |
| `-r, --ratings <R>` | Rating buckets | 2000,2200,2500 |
| `-s, --speeds <S>` | Time controls | blitz,rapid,classical |
| `--maia-model <path>` | Path to `maia3_simplified.onnx` | auto-detect |
| `--maia-elo <N>` | Elo for Maia predictions | 2200 |
| `--maia-min-prob <P>` | Skip Maia moves below this probability | 0.05 |

### Eval Window

| Option | Description | Default |
|--------|-------------|---------|
| `--min-eval <cp>` | Stop if our eval below this | Color-dependent |
| `--max-eval <cp>` | Stop if our eval above this | Color-dependent |
| `--relative` | Make thresholds relative to root eval | off |

### Examples

Build a Black repertoire with verbose output:
```bash
./bin/tree_builder -c b -e 20 -t 4 -v -n "Modern Benoni" modern_benoni
```

Build from a custom FEN:
```bash
./bin/tree_builder -c w --opp-max-children 4 \
  -f "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1" \
  e4_repertoire
```

Resume an interrupted build:
```bash
./bin/tree_builder -c b -v modern_benoni  # resumes from modern_benoni.tree.json
```

## API (Library Usage)

```c
#include "tree.h"
#include "lichess_api.h"
#include "engine_pool.h"
#include "serialization.h"

int main() {
    EnginePool *pool = engine_pool_create("./stockfish", 4, 20, 1);
    LichessExplorer *explorer = lichess_explorer_create();
    lichess_explorer_set_ratings(explorer, "2000,2200,2500");

    Tree *tree = tree_create();
    TreeConfig config = tree_config_default();
    config.play_as_white = true;
    config.engine_pool = pool;
    config.maia_only = false;  // this example uses Lichess for opponent moves
    config.min_probability = 0.001;
    tree_config_set_color_defaults(&config);

    tree_build(tree, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
               &config, explorer);

    SerializationOptions opts = serialization_options_default();
    tree_save(tree, "output.tree.json", &opts);

    tree_destroy(tree);
    lichess_explorer_destroy(explorer);
    engine_pool_destroy(pool);
    return 0;
}
```

## Algorithm Details

See [ALGORITHM.md](ALGORITHM.md) for the full algorithm design document
including expectimax math, parameter explanations, and data flow diagrams.

## License

AGPL-3.0 — see main project [LICENSE](../LICENSE) file.
