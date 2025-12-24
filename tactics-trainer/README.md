# Tactics Trainer

A chess tactics trainer that generates puzzles from your own games. Analyze your chess.com and lichess games with Stockfish running in your browser, then train on your mistakes.

## Architecture

- **Frontend**: Static HTML/CSS/JS site (Cloudflare Pages)
- **Backend**: FastAPI + SQLite (Contabo VPS)

## Features

- 🔐 Google Sign-In for authentication
- ♟️ Fetch games from Chess.com and Lichess
- 🧠 In-browser Stockfish analysis (WebAssembly)
- 📊 Automatic mistake detection (blunders, mistakes, inaccuracies)
- 🎯 Interactive puzzle training
- 🌐 Public tactics database - train on anyone's mistakes!

## API Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/api/tactics/{username}` | GET | Public | Get tactics for a user |
| `/api/tactics/{username}/stats` | GET | Public | Get user statistics |
| `/api/tactics` | POST | Required | Upload tactics (Google ID token) |
| `/api/tactics/{username}` | DELETE | Required | Delete your tactics |

## Deployment

### Frontend (Cloudflare Pages)

1. Push the `frontend/` directory to a Git repository
2. Connect to Cloudflare Pages
3. Build settings:
   - Build command: (none - it's static)
   - Build output directory: `/`
4. Set environment variables if needed

Or deploy manually:
```bash
cd frontend
npx wrangler pages publish . --project-name=tactics-trainer
```

### Backend (Contabo VPS)

#### Option 1: Docker

```bash
cd backend

# Build image
docker build -t tactics-trainer-api .

# Run with persistent data
docker run -d \
  --name tactics-api \
  -p 8000:8000 \
  -v /path/to/data:/data \
  -e GOOGLE_CLIENT_ID=your-client-id \
  tactics-trainer-api
```

#### Option 2: Systemd Service

```bash
# Install dependencies
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Create systemd service
sudo tee /etc/systemd/system/tactics-api.service << EOF
[Unit]
Description=Tactics Trainer API
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/tactics-trainer/backend
Environment=DATABASE_PATH=/var/lib/tactics-trainer/tactics.db
Environment=GOOGLE_CLIENT_ID=your-client-id
ExecStart=/opt/tactics-trainer/backend/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl enable tactics-api
sudo systemctl start tactics-api
```

#### Option 3: Nginx Reverse Proxy (Recommended for production)

```nginx
server {
    listen 80;
    server_name api.yourdomain.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/api.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Configuration

### Frontend Configuration

Edit `js/api.js` or use localStorage:

```javascript
// Set your backend URL
localStorage.setItem('backendUrl', 'https://api.yourdomain.com');

// Set Google Client ID
localStorage.setItem('googleClientId', 'your-google-client-id.apps.googleusercontent.com');
```

### Google OAuth Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable "Google Sign-In API"
4. Create OAuth 2.0 credentials (Web application)
5. Add authorized JavaScript origins:
   - `https://your-frontend-domain.pages.dev`
   - `http://localhost:8080` (for development)
6. Copy the Client ID

### Environment Variables (Backend)

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_PATH` | SQLite database file path | `tactics.db` |
| `GOOGLE_CLIENT_ID` | Google OAuth Client ID (for token verification) | (empty) |

## Development

### Run Backend Locally

```bash
cd backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

### Serve Frontend Locally

```bash
cd frontend
python -m http.server 8080
# or
npx serve .
```

## Security Notes

- The GET endpoints are intentionally public - tactics are not sensitive
- POST/DELETE require a valid Google ID token
- The backend verifies tokens with Google's tokeninfo endpoint
- CORS is configured to allow all origins (restrict in production)
- SQLite is fine for small-medium scale; upgrade to PostgreSQL for larger deployments

## License

MIT

