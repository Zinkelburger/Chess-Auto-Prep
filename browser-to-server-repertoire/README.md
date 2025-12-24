# Lichess Repertoire Sync

Chrome extension that integrates Lichess analysis board with your Chess-Auto-Prep Flutter app. Right-click on any move to save it to one of your repertoire files, with fuzzy search to quickly find the right repertoire.

## Features

- **Flutter App Integration** - The Flutter app runs the server automatically on desktop platforms (Linux, macOS, Windows)
- **No Python Server Required** - The Flutter app handles everything directly
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
4. Select the `browser-to-server-repertoire` directory
5. The extension is now installed!

## Quick Start

```bash
# 1. Install Chrome extension
# - Open chrome://extensions/
# - Enable "Developer mode"
# - Click "Load unpacked"
# - Select the browser-to-server-repertoire/ folder

# 2. Start the Flutter app on desktop
flutter run -d linux   # or -d macos, -d windows

# 3. Use it!
# - Go to lichess.org/analysis
# - Right-click any move
# - Click "Add to repertoire..."
# - Select your repertoire or search for it
# - Line is added to your chosen repertoire!
```

## How It Works

### Architecture

The Flutter app automatically starts an HTTP server on `localhost:9812` when running on desktop platforms (Linux, macOS, Windows). This server provides the same API that the browser extension expects:

- **GET /list-repertoires** - List all repertoire files with metadata
- **POST /add-line** - Add a line to a specific repertoire
- **GET /health** - Health check

The server is **not started** on:
- Mobile platforms (iOS, Android) - browser extension doesn't make sense there
- Web platform - browser security prevents running HTTP servers

### Usage

1. **Start the Flutter app** on a desktop platform (Linux, macOS, or Windows)
   - The server starts automatically on port 9812
   - You'll see console output: `[BrowserExtensionServer] Server started on http://localhost:9812`

2. **On Lichess**: Go to https://lichess.org/analysis

3. **Right-click** any move in the analysis board

4. **Click** "Add to repertoire..." in the context menu

5. **Select repertoire**:
   - Top 3 most recent repertoires shown by default
   - Type to fuzzy search all repertoires (e.g., "bnni" matches "Benoni")
   - Click the repertoire to add the line

6. **Done!** The line is saved to your chosen repertoire PGN file

## Legacy Python Server (Optional)

If you need to run the server independently (e.g., Flutter app not running), the Python server is still available:

```bash
# Install Python dependencies
pip install -r requirements.txt

# Start the server
python server.py
```

The Python server provides the same endpoints and is fully compatible with the browser extension.

## Server Endpoints

- **GET /list-repertoires** - List all repertoire files with metadata (name, modified time, line count)
- **POST /add-line** - Add a line to repertoire (queued, duplicate-checked)
  - Requires `targetRepertoire` field to specify which repertoire file
- **GET /health** - Health check with repertoire count and platform info

## Data Format

The browser extension sends POST requests to `http://localhost:9812/add-line` with this JSON structure:

```json
{
  "targetRepertoire": "Benoni.pgn",
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
    }
  ]
}
```

## Platform Support

| Platform | Server Support | Notes |
|----------|---------------|-------|
| Linux    | ✅ Supported  | Server starts automatically |
| macOS    | ✅ Supported  | Server starts automatically |
| Windows  | ✅ Supported  | Server starts automatically |
| Web      | ❌ Not supported | Browser security prevents HTTP servers |
| Android  | ❌ Not supported | Mobile - extension not applicable |
| iOS      | ❌ Not supported | Mobile - extension not applicable |

## Testing the Server

```bash
# Check if server is running
curl http://localhost:9812/health

# List all repertoires
curl http://localhost:9812/list-repertoires

# Add a test line
curl -X POST http://localhost:9812/add-line \
  -H "Content-Type: application/json" \
  -d '{
    "targetRepertoire": "Test.pgn",
    "moves": [
      {"ply": 1, "san": "e4"},
      {"ply": 2, "san": "e5"},
      {"ply": 3, "san": "Nf3"}
    ],
    "startFen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "variant": "standard"
  }'
```

## Troubleshooting

**Button doesn't appear:**
- Check browser console for errors (F12)
- Make sure you're on an analysis board page (lichess.org/analysis)
- Verify extension is enabled in `chrome://extensions/`
- Try reloading the Lichess page

**No repertoires showing in menu:**
- Verify Flutter app is running on desktop
- Check console output for `[BrowserExtensionServer] Server started` message
- Test server: `curl http://localhost:9812/list-repertoires`
- Check that repertoire directory has .pgn files

**"Failed to fetch repertoires" error:**
- Flutter app not running or not on desktop platform
- Wrong port - verify server is on localhost:9812
- Check browser console for CORS or network errors

**Line added to wrong file:**
- Verify you clicked the correct repertoire in the menu
- Check Flutter app console output to see which file was used

**Extension not loading:**
- Check manifest.json is valid JSON
- Ensure all file paths are correct
- Look for errors in `chrome://extensions/` page
- Try removing and re-adding the extension

## Files

- **Extension:**
  - `manifest.json` - Chrome extension configuration
  - `content.js` - Main script that injects into Lichess pages

- **Legacy Server (optional):**
  - `server.py` - Python server for standalone use
  - `test_server.py` - Test script to verify server works
  - `requirements.txt` - Python dependencies

## License

MIT
