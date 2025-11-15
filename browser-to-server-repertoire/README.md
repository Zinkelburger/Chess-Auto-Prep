# Lichess Repertoire Sync

Chrome extension that integrates Lichess analysis board with your Chess-Auto-Prep Flutter app. Right-click on any move to save it to one of your repertoire files, with fuzzy search to quickly find the right repertoire.

## Features

- **Flutter App Integration** - Automatically finds and uses your Flutter app's repertoire directory
- **Repertoire Selection Menu** - Choose which repertoire to add lines to
  - Shows 3 most recently modified repertoires by default
  - Fuzzy search to quickly find any repertoire
  - Displays line count for each repertoire
- **Full Move Capture** - Saves complete lines with:
  - Move sequence in PGN format
  - Comments on moves
  - Annotations/glyphs (!, ?, !!, ??, !?, ?!, etc.)
  - Engine evaluations
  - Position FENs
  - Variant information
- **Smart Duplicate Detection** - Won't add the same line twice to the same repertoire

## Installation

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable "Developer mode" (toggle in top right)
3. Click "Load unpacked"
4. Select the `browser_extension` directory
5. The extension is now installed!

## Quick Start

```bash
# 1. Install Python dependencies
cd browser-to-server-repertoire
pip install -r requirements.txt

# 2. (Optional) Find your repertoire directory
python find_repertoire_dir.py

# 3. Start the repertoire server
python server.py
# Or with custom directory:
# export REPERTOIRE_DIR=/path/to/your/repertoires
# python server.py

# 4. Install Chrome extension
# - Open chrome://extensions/
# - Enable "Developer mode"
# - Click "Load unpacked"
# - Select the browser-to-server-repertoire/ folder

# 5. Use it!
# - Go to lichess.org/analysis
# - Right-click any move
# - Click "Add to repertoire..."
# - Select your repertoire or search for it
# - Line is added to your chosen repertoire!
```

## Usage

1. **Start the server**: `python server.py`
   - Server automatically finds your Flutter app's repertoire directory
   - Searches common locations: `~/.local/share/com.example.chess_auto_prep/repertoires`, `~/Documents/Chess-Auto-Prep/repertoires`, etc.
   - Set `REPERTOIRE_DIR` environment variable to override

2. **On Lichess**: Go to https://lichess.org/analysis

3. **Right-click** any move in the analysis board

4. **Click** "Add to repertoire..." in the context menu

5. **Select repertoire**:
   - Top 3 most recent repertoires shown by default
   - Type to fuzzy search all repertoires (e.g., "bnni" matches "Benoni")
   - Click the repertoire to add the line

6. **Done!** The line is saved to your chosen repertoire PGN file

## Server

The included `server.py` saves all lines to `repertoire.pgn` in standard PGN format. The server uses the `python-chess` library to properly handle move parsing, annotations, and comments.

### Features

- **Duplicate detection** - Won't add the same line twice
- **Request queueing** - Handles multiple concurrent requests safely
- **Comments & annotations** - Preserves all move comments and glyphs (!, ?, !!, etc.)
- **Engine evaluations** - Includes eval scores in comments

### Server Endpoints

- **GET /list-repertoires** - List all repertoire files with metadata (name, modified time, line count)
- **POST /add-line** - Add a line to repertoire (queued, duplicate-checked)
  - Optional `targetRepertoire` field to specify which repertoire file
- **GET /health** - Health check with queue status

### Examples

```bash
# List all repertoires
curl http://localhost:9812/list-repertoires

# Check server health
curl http://localhost:9812/health

# View a specific repertoire (adjust path based on your system)
cat ~/.local/share/com.example.chess_auto_prep/repertoires/Benoni.pgn

# Find your repertoire directory
python find_repertoire_dir.py
```

## Data Format

The browser extension sends POST requests to `http://localhost:9812/add-line` with this JSON structure:

```json
{
  "targetRepertoire": "Benoni.pgn",  // Optional: which repertoire to add to
  "pgn": "1. e4 e5 2. Nf3! { Best move } 2... Nc6 3. Bb5",
  "startFen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
  "variant": "standard",
  "moves": [
    {
      "ply": 1,
      "moveNumber": 1,
      "color": "white",
      "san": "e4",
      "uci": "e2e4",
      "fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
      "comments": [],
      "glyphs": [],
      "eval": { "cp": 15, "mate": null, "best": "e7e5" }
    },
    {
      "ply": 2,
      "moveNumber": 1,
      "color": "black",
      "san": "e5",
      "uci": "e7e5",
      "fen": "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
      "comments": [],
      "glyphs": [],
      "eval": null
    },
    {
      "ply": 3,
      "moveNumber": 2,
      "color": "white",
      "san": "Nf3",
      "uci": "g1f3",
      "fen": "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
      "comments": ["Best move"],
      "glyphs": [{ "id": 1, "symbol": "!", "name": "Good move" }],
      "eval": { "cp": 20, "mate": null, "best": "b8c6" }
    }
  ]
}
```

### Server Output Example

```
======================================================================
Lichess Repertoire Server
======================================================================
Server:         http://localhost:9812
PGN file:       /home/user/repertoire.pgn

Endpoints:
  POST /add-line     - Add a line to repertoire PGN file
  GET  /lines        - Get recent lines (JSON)
  GET  /export       - Export entire PGN file
  GET  /stats        - Get repertoire statistics
  POST /clear        - Clear all lines (creates backup)
  GET  /health       - Health check
======================================================================

✓ Appended game to repertoire.pgn
  PGN: 1. e4! { Best move } e5 2. Nf3 Nc6 3. Bb5
  Moves: 6
  Total lines: 1
```

The server creates a properly formatted PGN file that looks like:

```pgn
[Event "Repertoire Line"]
[Site "Lichess Analysis"]
[Date "2025.10.29"]
[Round "?"]
[White "?"]
[Black "?"]
[Result "*"]

1. e4 $1 { Best move [+0.15] } 1... e5 2. Nf3 2... Nc6 3. Bb5 *
```

## Testing

Test the server without the browser extension:

```bash
# Start the server in one terminal
python server.py

# Run tests in another terminal
python test_server.py
```

The test script will:
- Check server health
- Add a sample Italian Game line with comments
- Test duplicate detection
- Test concurrent request handling

## Configuration

### Server Configuration

Set the repertoire directory via environment variable:
```bash
export REPERTOIRE_DIR=/path/to/your/repertoires
python server.py
```

The server automatically searches these locations (in order):
1. `$REPERTOIRE_DIR` (if set)
2. `~/.local/share/com.example.chess_auto_prep/repertoires`
3. `~/.local/share/com.example.auto_prep/repertoires`
4. `~/Documents/Chess-Auto-Prep/repertoires`
5. `./repertoires` (current directory)

### Extension Configuration

Edit `content.js` to change:
- `REPERTOIRE_SERVER` - Change port or server URL (line 7)
- `LIST_REPERTOIRES_URL` - Change repertoire list endpoint (line 8)
- `CACHE_DURATION` - How long to cache repertoire list in ms (line 13)
- `GLYPH_SYMBOLS` - Add/modify annotation symbols (lines 16-26)

## Files

- **Extension:**
  - `manifest.json` - Chrome extension configuration
  - `content.js` - Main script that injects into Lichess pages

- **Server:**
  - `server.py` - Main repertoire server with Flutter integration
  - `find_repertoire_dir.py` - Helper script to locate repertoire directory
  - `test_server.py` - Test script to verify server works
  - `requirements.txt` - Python dependencies

- **Documentation:**
  - `README.md` - This file

## Development

To modify the extension:
1. Edit the files
2. Go to `chrome://extensions/`
3. Click the refresh icon on the extension card
4. Reload the Lichess page

## Troubleshooting

**Button doesn't appear:**
- Check browser console for errors (F12)
- Make sure you're on an analysis board page (lichess.org/analysis)
- Verify extension is enabled in `chrome://extensions/`
- Try reloading the Lichess page

**No repertoires showing in menu:**
- Verify server is running: `curl http://localhost:9812/list-repertoires`
- Check repertoire directory exists and has .pgn files
- Run `python find_repertoire_dir.py` to verify location
- Check server console for errors

**"Failed to fetch repertoires" error:**
- Server not running - start with `python server.py`
- Wrong port - verify server is on localhost:9812
- Check browser console for CORS or network errors

**Server can't find repertoires:**
- Run `python find_repertoire_dir.py` to see which directories are checked
- Set `REPERTOIRE_DIR` environment variable to your repertoire location
- Make sure Flutter app has created the repertoires directory

**Line added to wrong file:**
- Check server console output to see which file was used
- Verify you clicked the correct repertoire in the menu

**Extension not loading:**
- Check manifest.json is valid JSON
- Ensure all file paths are correct
- Look for errors in `chrome://extensions/` page
- Try removing and re-adding the extension

## Icons

The extension currently references icon files but they're not included. Create simple PNG icons:
- `icon16.png` - 16x16 pixels
- `icon48.png` - 48x48 pixels
- `icon128.png` - 128x128 pixels

Or remove the `icons` field from `manifest.json` to use default Chrome extension icon.

## License

MIT
