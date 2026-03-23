# Chess Opening Tree Builder

A C library and CLI tool for building chess opening repertoire trees from Lichess explorer data.

## Features

- **Tree Building**: Traverse opening positions from Lichess database
- **Probability-based Pruning**: Stop exploring moves below a probability threshold
- **Lichess Statistics**: Capture white/black/draw rates for each position
- **Ease Score Calculation**: Compute ease scores based on move probabilities and engine evaluations
- **JSON Export**: Export trees for use with Python, Flutter, JavaScript, etc.
- **DOT/PGN Export**: Export for visualization or study

## Requirements

- GCC or Clang compiler
- libcurl development files

### Ubuntu/Debian
```bash
sudo apt install build-essential libcurl4-openssl-dev
```

### Fedora
```bash
sudo dnf install gcc make libcurl-devel
```

### macOS
```bash
brew install curl
```

## Building

```bash
cd tree_builder
make
```

The executable will be at `bin/tree_builder`.

## Usage

```bash
./bin/tree_builder [options] <output_file>
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-f, --fen <FEN>` | Starting position FEN | Standard starting position |
| `-p, --probability <P>` | Minimum probability threshold (0-1) | 0.0001 (0.01%) |
| `-d, --depth <N>` | Maximum depth in ply | 30 |
| `-r, --ratings <R>` | Comma-separated rating buckets | "1600,1800,2000,2200" |
| `-s, --speeds <S>` | Time controls | "rapid,classical" |
| `-g, --min-games <N>` | Minimum games per move | 10 |
| `-m, --masters` | Use masters database | - |
| `-v, --verbose` | Verbose progress output | - |
| `-h, --help` | Show help | - |

### Examples

Build a repertoire from starting position:
```bash
./bin/tree_builder repertoire.json
```

Build after 1.e4 with higher threshold:
```bash
./bin/tree_builder -f "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1" -p 0.01 e4_repertoire.json
```

Build from masters database:
```bash
./bin/tree_builder -m --masters opening.json
```

## Output Format

The output is JSON with this structure:

```json
{
  "format": "opening_tree",
  "version": 1.0,
  "total_nodes": 1234,
  "max_depth": 15,
  "config": {
    "min_probability": 0.0001,
    "max_depth": 30,
    "rating_range": "1600,1800,2000,2200",
    "speeds": "rapid,classical",
    "min_games": 10
  },
  "tree": {
    "id": 1,
    "depth": 0,
    "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "move_probability": 1.0,
    "cumulative_probability": 1.0,
    "white_wins": 123456,
    "black_wins": 123456,
    "draws": 123456,
    "total_games": 370368,
    "is_white_to_move": true,
    "children": [
      {
        "id": 2,
        "move_san": "e4",
        "move_uci": "e2e4",
        "move_probability": 0.35,
        "cumulative_probability": 0.35,
        ...
      }
    ]
  }
}
```

### Node Fields

| Field | Description |
|-------|-------------|
| `id` | Unique node identifier |
| `depth` | Depth from root (ply) |
| `fen` | FEN string of position |
| `move_san` | Move in SAN notation (e.g., "e4") |
| `move_uci` | Move in UCI notation (e.g., "e2e4") |
| `move_probability` | Probability of this move at this position |
| `cumulative_probability` | Product of probabilities from root |
| `engine_eval_cp` | Engine evaluation in centipawns |
| `ease` | Ease score [0.0-1.0] |
| `white_wins` | Number of white wins |
| `black_wins` | Number of black wins |
| `draws` | Number of draws |
| `total_games` | Total games in database |
| `is_white_to_move` | Whose turn it is |
| `children` | Child nodes (moves from this position) |

## Using the Tree in Other Languages

### Python

```python
import json

with open('repertoire.json', 'r') as f:
    data = json.load(f)

def traverse(node, depth=0):
    move = node.get('move_san', 'Start')
    prob = node.get('cumulative_probability', 1.0)
    print(f"{'  ' * depth}{move} ({prob:.2%})")
    
    for child in node.get('children', []):
        traverse(child, depth + 1)

traverse(data['tree'])
```

### JavaScript/Node.js

```javascript
const fs = require('fs');

const data = JSON.parse(fs.readFileSync('repertoire.json', 'utf8'));

function traverse(node, depth = 0) {
    const move = node.move_san || 'Start';
    const prob = node.cumulative_probability || 1.0;
    console.log('  '.repeat(depth) + `${move} (${(prob * 100).toFixed(2)}%)`);
    
    for (const child of node.children || []) {
        traverse(child, depth + 1);
    }
}

traverse(data.tree);
```

### Flutter/Dart

```dart
import 'dart:convert';
import 'dart:io';

class TreeNode {
  final int id;
  final String? moveSan;
  final double moveProbability;
  final double cumulativeProbability;
  final int whiteWins;
  final int blackWins;
  final int draws;
  final List<TreeNode> children;

  TreeNode.fromJson(Map<String, dynamic> json)
      : id = json['id'],
        moveSan = json['move_san'],
        moveProbability = json['move_probability'] ?? 1.0,
        cumulativeProbability = json['cumulative_probability'] ?? 1.0,
        whiteWins = json['white_wins'] ?? 0,
        blackWins = json['black_wins'] ?? 0,
        draws = json['draws'] ?? 0,
        children = (json['children'] as List<dynamic>?)
                ?.map((c) => TreeNode.fromJson(c))
                .toList() ??
            [];
}

void main() async {
  final file = File('repertoire.json');
  final data = jsonDecode(await file.readAsString());
  final tree = TreeNode.fromJson(data['tree']);
  
  print('Loaded tree with ${data['total_nodes']} nodes');
}
```

## Ease Score

The Ease score measures how "forgiving" a position is for the side to move:

- **Close to 1.0**: Natural human moves are also good moves (easy to play)
- **Close to 0.0**: Natural human moves are blunders (tricky position)

Formula:
```
Ease = 1 - (weighted_regret)^(1/3)
weighted_regret = Σ(probability^1.5 × normalized_regret)
regret = max(0, best_eval - move_eval) / 200
```

## API (Library Usage)

You can also use this as a library:

```c
#include "tree.h"
#include "lichess_api.h"
#include "serialization.h"

int main() {
    // Create explorer
    LichessExplorer *explorer = lichess_explorer_create();
    lichess_explorer_set_ratings(explorer, "2000,2200,2400");
    
    // Create and build tree
    Tree *tree = tree_create();
    TreeConfig config = tree_config_default();
    config.min_probability = 0.001;
    
    tree_build(tree, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
               &config, explorer);
    
    // Save
    tree_save(tree, "output.json", NULL);
    
    // Cleanup
    tree_destroy(tree);
    lichess_explorer_destroy(explorer);
    
    return 0;
}
```

## License

MIT License - see main project LICENSE file.

