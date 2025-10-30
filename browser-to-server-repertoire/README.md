# Lichess Repertoire Sync

Chrome extension that adds an "Add to repertoire" button to the Lichess analysis board context menu. Right-click on any move to save the entire line (with comments and annotations) to your local repertoire server.

## Features

- Adds "Add to repertoire" button to analysis board context menu
- Captures full move line with:
  - Move sequence in PGN format
  - Comments on moves
  - Annotations/glyphs (!, ?, !!, ??, !?, ?!, etc.)
  - Engine evaluations
  - Position FENs
  - Variant information
- Sends data to local repertoire server via HTTP POST

## Installation

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable "Developer mode" (toggle in top right)
3. Click "Load unpacked"
4. Select the `browser_extension` directory
5. The extension is now installed!

## Quick Start

```bash
# 1. Install Python dependencies
cd browser_extension
pip install -r requirements.txt

# 2. Start the repertoire server
python server.py

# 3. Install Chrome extension
# - Open chrome://extensions/
# - Enable "Developer mode"
# - Click "Load unpacked"
# - Select the browser_extension/ folder

# 4. Test the server (optional)
python test_server.py

# 5. Use it!
# - Go to lichess.org/analysis
# - Right-click any move
# - Click "Add to repertoire"
# - Check repertoire.pgn to see your saved lines!
```

## Usage

1. Start your repertoire server: `python server.py`
2. Go to any Lichess analysis board: https://lichess.org/analysis
3. Right-click on any move in the move list
4. Click "Add to repertoire"
5. The entire line (from start to clicked move, extended to the end) will be saved to `repertoire.pgn`

## Server

The included `server.py` saves all lines to `repertoire.pgn` in standard PGN format. The server uses the `python-chess` library to properly handle move parsing, annotations, and comments.

### Features

- **Duplicate detection** - Won't add the same line twice
- **Request queueing** - Handles multiple concurrent requests safely
- **Comments & annotations** - Preserves all move comments and glyphs (!, ?, !!, etc.)
- **Engine evaluations** - Includes eval scores in comments

### Server Endpoints

- **POST /add-line** - Add a line to repertoire (queued, duplicate-checked)
- **GET /health** - Health check with queue status

### Examples

```bash
# View your repertoire
cat repertoire.pgn

# Check server health
curl http://localhost:9812/health
```

## Data Format

The browser extension sends POST requests to `http://localhost:9812/add-line` with this JSON structure:

```json
{
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

Edit `content.js` to change:
- `REPERTOIRE_SERVER` - Change port or server URL (line 6)
- `GLYPH_SYMBOLS` - Add/modify annotation symbols (lines 9-27)

## Files

- **Extension:**
  - `manifest.json` - Chrome extension configuration
  - `content.js` - Main script that injects into Lichess pages

- **Server:**
  - `server.py` - Main repertoire server (appends to PGN file)
  - `test_server.py` - Test script to verify server works
  - `example-server.py` - Simple example server (saves to JSON)
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
- Make sure you're on an analysis board page
- Verify extension is enabled in `chrome://extensions/`

**Server request fails:**
- Check that your server is running on port 9812
- Look for CORS errors in console
- Verify server accepts JSON POST requests

**Extension not loading:**
- Check manifest.json is valid JSON
- Ensure all file paths are correct
- Look for errors in `chrome://extensions/` page

## Icons

The extension currently references icon files but they're not included. Create simple PNG icons:
- `icon16.png` - 16x16 pixels
- `icon48.png` - 48x48 pixels
- `icon128.png` - 128x128 pixels

Or remove the `icons` field from `manifest.json` to use default Chrome extension icon.

## License

MIT
