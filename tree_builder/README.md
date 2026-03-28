# Chess Opening Tree Builder

A C CLI tool that builds chess opening repertoires by interleaving Lichess
database queries with Stockfish evaluation. Branches are pruned inline by
eval window, producing a focused repertoire tree with evaluations on every
node.

## Architecture

**Single interleaved DFS** — no separate build/eval/discovery stages:

- **Our-move nodes**: Stockfish MultiPV finds candidate moves → eval filter →
  depth-dependent candidate cap → Lichess enrichment for SAN/win rates
- **Opponent-move nodes**: Lichess DB moves first, then Maia fills remaining
  mass with predicted human moves (a single node can have both sources) +
  engine top-1 → batch eval all children
- **Eval-window pruning** at every node — stop exploring when positions
  leave `[min_eval, max_eval]`
- **All evals cached** in SQLite for instant resume

## Requirements

- GCC or Clang compiler
- libcurl development files
- Stockfish binary (required for building)

### Fedora
```bash
sudo dnf install gcc make libcurl-devel
```

### Ubuntu/Debian
```bash
sudo apt install build-essential libcurl4-openssl-dev
```

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
| `-c, --color <w\|b>` | Play as white or black | w |
| `-p, --probability <P>` | Min probability threshold | 0.0001 (0.01%) |
| `-d, --depth <N>` | Max depth in ply | 30 |
| `-e, --eval-depth <N>` | Stockfish search depth | 20 |
| `-t, --threads <N>` | Parallel Stockfish engines | 4 |
| `-S, --stockfish <path>` | Stockfish binary path | auto-detect |
| `-n, --name <name>` | Repertoire name (shown in PGN headers) | |
| `-v, --verbose` | Verbose progress | |

### Our-Move Candidates (Engine-Driven)

| Option | Description | Default |
|--------|-------------|---------|
| `--our-multipv-root <N>` | MultiPV at root (explore broadly) | 10 |
| `--our-multipv-floor <N>` | MultiPV floor (deep positions) | 2 |
| `--taper-depth <N>` | Ply at which MultiPV bottoms out | 8 |
| `--max-eval-loss <cp>` | Skip candidates worse than best by this | 50 |

### Opponent Responses (Lichess + Maia)

| Option | Description | Default |
|--------|-------------|---------|
| `--opp-max-children <N>` | Max opponent responses | 6 |
| `--opp-mass-root <0-1>` | Mass target at root (explore broadly) | 0.95 |
| `--opp-mass-floor <0-1>` | Mass target floor (deep positions) | 0.50 |
| `-g, --min-games <N>` | Min games per move (Lichess) | 10 |
| `-r, --ratings <R>` | Rating buckets | 2000,2200,2500 |
| `-s, --speeds <S>` | Time controls | blitz,rapid,classical |
| `--maia-only` | Use Maia exclusively (no Lichess API) | off |
| `--maia-model <path>` | Path to `maia_rapid.onnx` | auto-detect |
| `--maia-elo <N>` | Elo for Maia predictions | 2000 |
| `--maia-threshold <P>` | Min cumProb for Maia supplement | 0.01 |
| `--maia-min-prob <P>` | Skip Maia moves below this | 0.02 |

### Eval Window

| Option | Description | Default |
|--------|-------------|---------|
| `--min-eval <cp>` | Stop if our eval below this | Color-dependent |
| `--max-eval <cp>` | Stop if our eval above this | Color-dependent |
| `--relative` | Make thresholds relative to root eval | off |

### ECA Scoring

| Option | Description | Default |
|--------|-------------|---------|
| `--eval-weight <0-1>` | Eval vs trickiness blend | 0.40 |
| `--eval-guard <0-1>` | Min win probability for a move | 0.35 |
| `--depth-decay <0-1>` | Depth discount for ECA | 1.0 |

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
    EnginePool *pool = engine_pool_create("./stockfish", 4, 20);
    LichessExplorer *explorer = lichess_explorer_create();
    lichess_explorer_set_ratings(explorer, "2000,2200,2500");

    Tree *tree = tree_create();
    TreeConfig config = tree_config_default();
    config.play_as_white = true;
    config.engine_pool = pool;
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
including ECA math, parameter explanations, and data flow diagrams.

## License

MIT License - see main project LICENSE file.
