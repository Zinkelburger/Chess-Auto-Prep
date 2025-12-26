# Tactics Trainer

A chess tactics trainer that generates puzzles from your own games. Analyze your chess.com and lichess games with Stockfish running in your browser, then train on your mistakes.

## Features

- ♟️ Fetch games from Chess.com and Lichess
- 🧠 In-browser Stockfish analysis (WebAssembly)
- 📊 Automatic mistake detection (blunders, mistakes)
- 🎯 Interactive puzzle training
- ⚙️ Time control filtering (bullet, blitz, rapid, classical, daily)

## How It Works

1. Enter your Chess.com or Lichess username
2. Select time controls and number of games to analyze
3. The app downloads your games and analyzes them with Stockfish in your browser
4. Mistakes and blunders are converted into training puzzles
5. Practice finding the best moves you missed!

## Deployment (Cloudflare Pages)

1. Push the `frontend/` directory to a Git repository
2. Connect to Cloudflare Pages
3. Build settings:
   - Build command: `npm run build`
   - Build output directory: `dist`

Or deploy manually:
```bash
cd frontend
npm install
npm run build
npx wrangler pages publish dist --project-name=tactics-trainer
```

## Development

### Serve Frontend Locally

```bash
cd frontend
npm install
npm run dev
```

Or without build tools:
```bash
cd frontend
python -m http.server 8080
# or
npx serve .
```

## License

MIT
