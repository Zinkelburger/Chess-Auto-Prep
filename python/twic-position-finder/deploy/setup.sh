#!/usr/bin/env bash
set -euo pipefail

# ── TWIC Position Finder — Server Setup ──────────────────────────
#
# Run on a fresh VPS (Ubuntu/Debian). Assumes you've already:
#   1. Pointed api.chessautoprep.com DNS to this server
#   2. Have your .env file ready (copy from .env.example)
#
# Usage:
#   chmod +x deploy/setup.sh
#   sudo deploy/setup.sh

APP_DIR=/opt/twic-position-finder
APP_USER=twic

echo "==> Installing system packages"
apt-get update -qq
apt-get install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx

echo "==> Creating service user"
id -u "$APP_USER" &>/dev/null || useradd --system --create-home "$APP_USER"

echo "==> Setting up app directory"
mkdir -p "$APP_DIR"
cp models.py downloader.py ingest.py query.py server.py weekly.py \
   email_sender.py lichess.py requirements.txt "$APP_DIR/"

echo "==> Creating Python virtualenv"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

echo "==> Copying .env (if present)"
if [ -f .env ]; then
    cp .env "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
    chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
fi

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

echo "==> Installing systemd units"
cp deploy/twic-api.service /etc/systemd/system/
cp deploy/twic-weekly.service /etc/systemd/system/
cp deploy/twic-weekly.timer /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now twic-api.service
systemctl enable --now twic-weekly.timer

echo "==> Setting up nginx reverse proxy"
cp deploy/nginx-api.conf /etc/nginx/sites-available/twic-api
ln -sf /etc/nginx/sites-available/twic-api /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "==> Getting SSL certificate"
certbot --nginx -d api.chessautoprep.com --non-interactive --agree-tos --redirect

echo ""
echo "==> Done! Services running:"
echo "    API:    systemctl status twic-api"
echo "    Timer:  systemctl status twic-weekly.timer"
echo "    Logs:   journalctl -u twic-api -f"
echo ""
echo "==> Initial data ingest (run manually as the twic user):"
echo "    sudo -u $APP_USER $APP_DIR/venv/bin/python $APP_DIR/ingest.py --from 1637"
