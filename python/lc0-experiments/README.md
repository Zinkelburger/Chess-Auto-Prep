# LC0 Experiments - WLD Analysis Tools

This directory contains Python scripts for analyzing chess positions and games using LC0 (LeelaChessZero) to extract Win/Loss/Draw percentages and other metrics.

## Setup

1. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

2. **Ensure LC0 is available:**
   - The scripts default to using: `/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0`
   - Make sure you have a neural network file (*.pb.gz) in the same directory as the LC0 binary
   - You can specify a different path using `--engine-path`

## Scripts

### 1. wld_calculator.py - Basic WLD Calculator

Analyzes single positions and provides Win/Loss/Draw percentages.

**Usage:**
```bash
# Analyze starting position
python wld_calculator.py

# Analyze a specific position
python wld_calculator.py --fen "r1bq1rk1/pp2nppp/2n1b3/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 9"

# Use longer analysis time
python wld_calculator.py --time 5.0

# Use CPU backend instead of OpenCL
python wld_calculator.py --backend cpu
```

**Output:**
```
Position: r1bq1rk1/pp2nppp/2n1b3/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 9
Evaluation: +0.45
Best Move: Nd5
Depth: 25, Nodes: 2,147,483
----------------------------------------
Win:  42.3%
Draw: 35.2%
Loss: 22.5%
----------------------------------------
```

### 2. sharpness_analyzer.py - Position Sharpness Analysis

Calculates position "sharpness" based on draw probability. Sharp positions have fewer draws.

**Usage:**
```bash
# Analyze default sharp position
python sharpness_analyzer.py

# Analyze tactical positions
python sharpness_analyzer.py --preset tactical

# Analyze endgame positions
python sharpness_analyzer.py --preset endgame

# Analyze custom position
python sharpness_analyzer.py --fen "your_fen_here"

# Analyze multiple positions from file
python sharpness_analyzer.py --positions-file positions.txt

# Save results to JSON
python sharpness_analyzer.py --output results.json
```

**Sharpness Formula:**
```
Sharpness Score = 100 / Draw_Percentage
```

- **< 2.0**: Very Drawish (boring/technical)
- **2.0-3.0**: Drawish (slightly drawish)
- **3.0-4.0**: Balanced (dynamic)
- **4.0-6.0**: Sharp (tactical)
- **> 6.0**: Very Sharp (extremely complex)

### 3. game_analyzer.py - Complete Game Analysis

Analyzes entire games move by move, tracking WLD evolution and identifying critical moments.

**Usage:**
```bash
# Analyze sample game (Kasparov vs Anand)
python game_analyzer.py --sample-game

# Analyze game from PGN file
python game_analyzer.py --pgn-file mygame.pgn

# Analyze first 20 moves only
python game_analyzer.py --sample-game --max-moves 20

# Generate plot of WLD evolution
python game_analyzer.py --sample-game --plot game_analysis.png

# Save detailed results to JSON
python game_analyzer.py --sample-game --output detailed_results.json

# Faster analysis (less time per position)
python game_analyzer.py --sample-game --time 0.5
```

**Features:**
- Move-by-move WLD tracking
- Momentum shift detection (>10% advantage change)
- Critical moment identification
- Visual plots of game progression
- Game statistics and averages

## Configuration Options

All scripts support these common options:

- `--engine-path`: Path to LC0 binary (default: `/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0`)
- `--backend`: Engine backend - `opencl`, `cuda`, or `cpu` (default: `opencl`)
- `--time`: Analysis time in seconds per position (default varies by script)

## Examples

### Quick Position Analysis
```bash
# Is this position sharp or drawish?
python sharpness_analyzer.py --fen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
```

### Game Flow Analysis
```bash
# How did the evaluation change throughout the game?
python game_analyzer.py --pgn-file "worldchampionship.pgn" --plot "wc_analysis.png"
```

### Bulk Position Analysis
```bash
# Analyze many positions for sharpness
echo "fen1" > positions.txt
echo "fen2" >> positions.txt
echo "fen3" >> positions.txt
python sharpness_analyzer.py --positions-file positions.txt --output bulk_results.json
```

## Troubleshooting

1. **"Engine not found"**: Check that `--engine-path` points to the correct LC0 binary
2. **"No WLD stats"**: Ensure you have a neural network file (*.pb.gz) in the LC0 directory
3. **GPU not detected**: Try `--backend cpu` or check your OpenCL/CUDA installation
4. **Import errors**: Run `pip install -r requirements.txt`

## Performance Tips

- Use shorter analysis times (`--time 0.5`) for quick analysis
- Use `--backend cpu` if GPU setup is problematic
- Limit game analysis with `--max-moves` for faster results
- Use preset positions for consistent benchmarking