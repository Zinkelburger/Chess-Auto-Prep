"""FastAPI backend for TWIC Position Finder — email auth and subscription management."""

import logging
import os
import time
from pathlib import Path

import requests as http_requests
from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.responses import Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

from models import (
    get_db, create_user, verify_user, get_user_by_auth, get_user_by_email,
    add_subscription, get_subscriptions, delete_subscription,
    deactivate_subscription, validate_fen, rotate_auth_token, revoke_auth_token,
    count_user_subscriptions, create_email_token, consume_email_token,
    cleanup_expired_email_tokens,
)
from email_sender import send_verification_email, send_login_email

log = logging.getLogger(__name__)

DB_PATH = Path(os.getenv("TWIC_DB_PATH", Path(__file__).parent / "positions.db"))
FRONTEND_ORIGIN = os.getenv("TWIC_FRONTEND_ORIGIN", "https://chessautoprep.com")
TURNSTILE_SECRET = os.getenv("TURNSTILE_SECRET_KEY", "")
DEBUG = os.getenv("TWIC_DEBUG", "").lower() in ("1", "true", "yes")
MAX_SUBSCRIPTIONS = 20

if not TURNSTILE_SECRET:
    log.warning("TURNSTILE_SECRET_KEY is not set — CAPTCHA verification is disabled")

limiter = Limiter(key_func=get_remote_address)
app = FastAPI(title="TWIC Position Finder", version="1.0.0")
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

_cors_origins = [FRONTEND_ORIGIN]
if DEBUG:
    _cors_origins += ["http://localhost:4321", "http://localhost:3000"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

bearer_scheme = HTTPBearer()

_last_token_cleanup = 0.0
_TOKEN_CLEANUP_INTERVAL = 6 * 3600


def db():
    global _last_token_cleanup
    conn = get_db(DB_PATH)
    try:
        if time.time() - _last_token_cleanup > _TOKEN_CLEANUP_INTERVAL:
            _last_token_cleanup = time.time()
            removed = cleanup_expired_email_tokens(conn)
            if removed:
                log.info("Cleaned up %d expired email token(s)", removed)
        yield conn
    finally:
        conn.close()


def auth_user(credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
              conn=Depends(db)):
    user = get_user_by_auth(conn, credentials.credentials)
    if not user:
        raise HTTPException(401, "Invalid or expired token")
    return user


# ── Turnstile ─────────────────────────────────────────────────────────


def _client_ip(request: Request) -> str | None:
    return (
        request.headers.get("CF-Connecting-IP")
        or request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        or (request.client.host if request.client else None)
    ) or None


def verify_turnstile(token: str, ip: str | None = None) -> bool:
    if not TURNSTILE_SECRET:
        return True
    if not token:
        log.warning("Turnstile token missing from request")
        return False
    try:
        payload: dict = {"secret": TURNSTILE_SECRET, "response": token}
        if ip:
            payload["remoteip"] = ip
        resp = http_requests.post(
            "https://challenges.cloudflare.com/turnstile/v0/siteverify",
            data=payload,
            timeout=10,
        )
        result = resp.json()
        if not result.get("success"):
            log.warning("Turnstile validation failed: %s", result.get("error-codes", []))
        return result.get("success", False)
    except Exception as e:
        log.error("Turnstile siteverify request failed: %s", e)
        return False


# ── Subscribe (landing page form) ────────────────────────────────────


class SubscribeRequest(BaseModel):
    email: EmailStr
    cf_turnstile_token: str = ""
    label: str = ""
    fen: str | None = None
    player: str | None = None
    white: str | None = None
    black: str | None = None
    exclude_site: str | None = None
    site: str | None = None
    min_elo: int | None = None
    max_elo: int | None = None
    eco: str | None = None
    time_control: str | None = None
    result: str | None = None
    event: str | None = None


@app.post("/api/subscribe")
@limiter.limit("5/minute")
def subscribe(req: SubscribeRequest, request: Request, conn=Depends(db)):
    if TURNSTILE_SECRET and not verify_turnstile(req.cf_turnstile_token, _client_ip(request)):
        raise HTTPException(400, "CAPTCHA verification failed. Please try again.")

    if not req.fen and not req.player and not req.white and not req.black and not req.eco:
        raise HTTPException(400, "At least one filter (FEN, player, ECO) is required.")

    if req.fen:
        try:
            validate_fen(req.fen)
        except ValueError:
            raise HTTPException(400, "Invalid FEN position. Please check the format.")

    existing = get_user_by_email(conn, req.email)

    if existing and existing.get("verified"):
        login_token = create_email_token(conn, existing["id"], "login")
        send_login_email(existing["email"], login_token)
        return {"status": "already_verified",
                "message": "You're already subscribed. Check your email for a link to manage your subscriptions."}

    user = create_user(conn, req.email)
    add_subscription(
        conn, user["id"],
        label=req.label, fen=req.fen, player=req.player,
        white=req.white, black=req.black,
        exclude_site=req.exclude_site, site=req.site,
        min_elo=req.min_elo, max_elo=req.max_elo, eco=req.eco,
        time_control=req.time_control, result=req.result,
        event=req.event, active=False,
    )
    send_verification_email(req.email, user["verify_token"])
    return {"status": "verification_sent",
            "message": "Check your email for a verification link to activate your subscription."}


# ── Email verification & login ────────────────────────────────────────


class VerifyRequest(BaseModel):
    token: str


@app.post("/api/verify")
@limiter.limit("10/minute")
def verify(req: VerifyRequest, request: Request, conn=Depends(db)):
    user = verify_user(conn, req.token)
    if not user:
        raise HTTPException(400, "Invalid or expired verification token")
    auth_token = rotate_auth_token(conn, user["id"])
    return {"status": "verified", "email": user["email"],
            "auth_token": auth_token,
            "message": "Email verified! Redirecting to your dashboard..."}


class LoginRequest(BaseModel):
    email: EmailStr


@app.post("/api/login")
@limiter.limit("5/minute")
def login(req: LoginRequest, request: Request, conn=Depends(db)):
    user = get_user_by_email(conn, req.email)
    if not user or not user.get("verified"):
        raise HTTPException(400, "Email not found or not verified. Please register first.")
    login_token = create_email_token(conn, user["id"], "login")
    send_login_email(user["email"], login_token)
    return {"status": "login_sent",
            "message": "Check your email for your login link."}


class ExchangeTokenRequest(BaseModel):
    token: str


@app.post("/api/exchange-token")
@limiter.limit("10/minute")
def exchange_token(req: ExchangeTokenRequest, request: Request, conn=Depends(db)):
    result = consume_email_token(conn, req.token, "login")
    if not result:
        raise HTTPException(401, "Invalid, expired, or already-used token")
    user = conn.execute("SELECT * FROM users WHERE id = ? AND verified = 1",
                        (result["user_id"],)).fetchone()
    if not user:
        raise HTTPException(401, "User not found or not verified")
    new_token = rotate_auth_token(conn, user["id"])
    return {"auth_token": new_token}


# ── Dashboard (authenticated) ────────────────────────────────────────


@app.get("/api/me")
def get_me(user=Depends(auth_user), conn=Depends(db)):
    sub_count = conn.execute(
        "SELECT COUNT(*) FROM subscriptions WHERE user_id = ? AND active = 1",
        (user["id"],),
    ).fetchone()[0]
    return {
        "email": user["email"],
        "verified": bool(user["verified"]),
        "subscription_count": sub_count,
    }


class SubscriptionCreate(BaseModel):
    label: str = ""
    fen: str | None = None
    player: str | None = None
    white: str | None = None
    black: str | None = None
    exclude_site: str | None = None
    site: str | None = None
    min_elo: int | None = None
    max_elo: int | None = None
    eco: str | None = None
    time_control: str | None = None
    result: str | None = None
    event: str | None = None


@app.get("/api/subscriptions")
def list_subscriptions(user=Depends(auth_user), conn=Depends(db)):
    subs = get_subscriptions(conn, user["id"])
    return {"subscriptions": subs}


@app.post("/api/subscriptions")
def create_subscription(req: SubscriptionCreate, user=Depends(auth_user),
                        conn=Depends(db)):
    if count_user_subscriptions(conn, user["id"]) >= MAX_SUBSCRIPTIONS:
        raise HTTPException(400, f"Maximum of {MAX_SUBSCRIPTIONS} active subscriptions reached")
    if not req.fen and not req.player and not req.white and not req.black and not req.eco:
        raise HTTPException(400, "At least one filter (FEN, player, ECO) is required")

    if req.fen:
        try:
            validate_fen(req.fen)
        except ValueError:
            raise HTTPException(400, "Invalid FEN position. Please check the format.")

    sub = add_subscription(
        conn, user["id"],
        label=req.label, fen=req.fen, player=req.player,
        white=req.white, black=req.black,
        exclude_site=req.exclude_site, site=req.site,
        min_elo=req.min_elo, max_elo=req.max_elo, eco=req.eco,
        time_control=req.time_control, result=req.result,
        event=req.event,
    )
    return {"subscription": sub}


@app.delete("/api/subscriptions/{sub_id}")
def remove_subscription(sub_id: int, user=Depends(auth_user), conn=Depends(db)):
    ok = delete_subscription(conn, sub_id, user["id"])
    if not ok:
        raise HTTPException(404, "Subscription not found")
    return {"status": "deleted"}


@app.get("/api/subscriptions/{sub_id}/pgn")
def download_subscription_pgn(sub_id: int, user=Depends(auth_user), conn=Depends(db)):
    sub = conn.execute(
        "SELECT * FROM subscriptions WHERE id = ? AND user_id = ?",
        (sub_id, user["id"]),
    ).fetchone()
    if not sub:
        raise HTTPException(404, "Subscription not found")

    rows = conn.execute(
        """SELECT g.pgn_text FROM games g
           JOIN notifications_sent n ON n.game_id = g.id
           WHERE n.subscription_id = ?
           ORDER BY COALESCE(g.white_elo, 0) + COALESCE(g.black_elo, 0) DESC""",
        (sub_id,),
    ).fetchall()

    if not rows:
        raise HTTPException(404, "No matched games found for this subscription")

    pgn_content = "\n\n".join(r["pgn_text"] for r in rows if r["pgn_text"])
    label = sub["label"] or f"subscription_{sub_id}"
    filename = f"{label.replace(' ', '_')}.pgn"

    return Response(
        content=pgn_content,
        media_type="application/x-chess-pgn",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


class UnsubscribeRequest(BaseModel):
    token: str
    sub: int


@app.post("/api/unsubscribe")
@limiter.limit("10/minute")
def unsubscribe(req: UnsubscribeRequest, request: Request, conn=Depends(db)):
    result = consume_email_token(conn, req.token, "unsubscribe")
    if not result:
        raise HTTPException(401, "Invalid, expired, or already-used unsubscribe link")
    if result["subscription_id"] is not None and result["subscription_id"] != req.sub:
        raise HTTPException(400, "Token does not match the requested subscription")
    ok = deactivate_subscription(conn, req.sub, result["user_id"])
    if not ok:
        raise HTTPException(404, "Subscription not found or already inactive")
    return {"status": "unsubscribed", "subscription_id": req.sub}


@app.post("/api/logout")
def logout(user=Depends(auth_user), conn=Depends(db)):
    revoke_auth_token(conn, user["id"])
    return {"status": "logged_out"}


# ── Dev-only ──────────────────────────────────────────────────────────

if DEBUG:
    @app.post("/api/dev-login")
    def dev_login(req: LoginRequest, conn=Depends(db)):
        user = get_user_by_email(conn, req.email)
        if not user:
            raise HTTPException(404, "User not found")
        if not user.get("verified"):
            conn.execute(
                "UPDATE users SET verified = 1, verified_at = ?, verify_token = NULL "
                "WHERE id = ?",
                (time.time(), user["id"]),
            )
            from models import activate_user_subscriptions
            activate_user_subscriptions(conn, user["id"])
            conn.commit()
        login_token = create_email_token(conn, user["id"], "login")
        return {"login_url": f"{FRONTEND_ORIGIN}/dashboard?token={login_token}",
                "token": login_token}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
