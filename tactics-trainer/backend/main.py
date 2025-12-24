"""
Tactics Trainer Backend API
- Public GET /api/tactics/{username} - returns all tactics for a username
- Authenticated POST /api/tactics - upload tactics (requires Google ID token)
"""

import os
import json
import aiosqlite
import httpx
from datetime import datetime
from typing import Optional, List
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Depends, Header, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Configuration
DATABASE_PATH = os.environ.get("DATABASE_PATH", "tactics.db")
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")

# --- Models ---

class TacticsPosition(BaseModel):
    fen: str
    user_move: str
    correct_line: List[str]
    mistake_type: str  # "?" or "??" or "?!"
    mistake_analysis: str
    position_context: str  # "Move X, Color to play"
    game_white: str
    game_black: str
    game_result: str
    game_date: str
    game_id: str
    game_url: str = ""
    difficulty: int = 1

class TacticsUpload(BaseModel):
    username: str  # chess.com or lichess username
    platform: str  # "chesscom" or "lichess"
    tactics: List[TacticsPosition]

class TacticsResponse(BaseModel):
    id: int
    username: str
    platform: str
    fen: str
    user_move: str
    correct_line: List[str]
    mistake_type: str
    mistake_analysis: str
    position_context: str
    game_white: str
    game_black: str
    game_result: str
    game_date: str
    game_id: str
    game_url: str
    difficulty: int
    created_at: str

class UserStats(BaseModel):
    username: str
    platform: str
    total_tactics: int
    blunders: int
    mistakes: int
    inaccuracies: int

# --- Database ---

async def init_db():
    """Initialize SQLite database with required tables."""
    async with aiosqlite.connect(DATABASE_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS tactics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                platform TEXT NOT NULL,
                fen TEXT NOT NULL,
                user_move TEXT NOT NULL,
                correct_line TEXT NOT NULL,
                mistake_type TEXT NOT NULL,
                mistake_analysis TEXT,
                position_context TEXT,
                game_white TEXT,
                game_black TEXT,
                game_result TEXT,
                game_date TEXT,
                game_id TEXT,
                game_url TEXT,
                difficulty INTEGER DEFAULT 1,
                created_at TEXT NOT NULL,
                uploader_email TEXT,
                UNIQUE(username, platform, fen, user_move)
            )
        """)
        
        # Index for fast username lookups
        await db.execute("""
            CREATE INDEX IF NOT EXISTS idx_tactics_username 
            ON tactics(username, platform)
        """)
        
        await db.commit()

async def get_db():
    """Get database connection."""
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        yield db

# --- Auth ---

async def verify_google_token(authorization: Optional[str] = Header(None)) -> dict:
    """
    Verify Google ID token from Authorization header.
    Returns user info if valid, raises HTTPException if not.
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="Authorization header required")
    
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid authorization format. Use: Bearer <token>")
    
    token = authorization[7:]  # Remove "Bearer " prefix
    
    # Verify token with Google
    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(
                f"https://oauth2.googleapis.com/tokeninfo?id_token={token}"
            )
            
            if response.status_code != 200:
                raise HTTPException(status_code=401, detail="Invalid Google token")
            
            token_info = response.json()
            
            # Verify audience matches our client ID (if configured)
            if GOOGLE_CLIENT_ID and token_info.get("aud") != GOOGLE_CLIENT_ID:
                raise HTTPException(status_code=401, detail="Token not for this application")
            
            return {
                "email": token_info.get("email"),
                "name": token_info.get("name"),
                "picture": token_info.get("picture"),
                "sub": token_info.get("sub"),  # Google user ID
            }
            
        except httpx.RequestError as e:
            raise HTTPException(status_code=500, detail=f"Failed to verify token: {e}")

# --- Lifespan ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize database on startup."""
    await init_db()
    yield

# --- App ---

app = FastAPI(
    title="Tactics Trainer API",
    description="Store and retrieve chess tactics from your games",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS - Allow frontend from anywhere (Cloudflare Pages domains)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict to your Cloudflare Pages domain
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Routes ---

@app.get("/")
async def root():
    """Health check endpoint."""
    return {"status": "ok", "service": "tactics-trainer"}

@app.get("/api/tactics/{username}", response_model=List[TacticsResponse])
async def get_tactics(
    username: str,
    platform: Optional[str] = Query(None, description="Filter by platform: chesscom or lichess"),
    limit: int = Query(100, ge=1, le=1000, description="Max number of tactics to return"),
    offset: int = Query(0, ge=0, description="Offset for pagination"),
):
    """
    Get all tactics for a username. This is PUBLIC - no auth required.
    Anyone can view anyone's tactics to train with.
    """
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        if platform:
            query = """
                SELECT * FROM tactics 
                WHERE LOWER(username) = LOWER(?) AND platform = ?
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?
            """
            cursor = await db.execute(query, (username, platform, limit, offset))
        else:
            query = """
                SELECT * FROM tactics 
                WHERE LOWER(username) = LOWER(?)
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?
            """
            cursor = await db.execute(query, (username, limit, offset))
        
        rows = await cursor.fetchall()
        
        return [
            TacticsResponse(
                id=row["id"],
                username=row["username"],
                platform=row["platform"],
                fen=row["fen"],
                user_move=row["user_move"],
                correct_line=json.loads(row["correct_line"]),
                mistake_type=row["mistake_type"],
                mistake_analysis=row["mistake_analysis"] or "",
                position_context=row["position_context"] or "",
                game_white=row["game_white"] or "",
                game_black=row["game_black"] or "",
                game_result=row["game_result"] or "",
                game_date=row["game_date"] or "",
                game_id=row["game_id"] or "",
                game_url=row["game_url"] or "",
                difficulty=row["difficulty"] or 1,
                created_at=row["created_at"],
            )
            for row in rows
        ]

@app.get("/api/tactics/{username}/stats", response_model=UserStats)
async def get_user_stats(username: str, platform: Optional[str] = Query(None)):
    """Get statistics for a user's tactics. PUBLIC endpoint."""
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        if platform:
            query = """
                SELECT 
                    COUNT(*) as total,
                    SUM(CASE WHEN mistake_type = '??' THEN 1 ELSE 0 END) as blunders,
                    SUM(CASE WHEN mistake_type = '?' THEN 1 ELSE 0 END) as mistakes,
                    SUM(CASE WHEN mistake_type = '?!' THEN 1 ELSE 0 END) as inaccuracies
                FROM tactics 
                WHERE LOWER(username) = LOWER(?) AND platform = ?
            """
            cursor = await db.execute(query, (username, platform))
        else:
            query = """
                SELECT 
                    COUNT(*) as total,
                    SUM(CASE WHEN mistake_type = '??' THEN 1 ELSE 0 END) as blunders,
                    SUM(CASE WHEN mistake_type = '?' THEN 1 ELSE 0 END) as mistakes,
                    SUM(CASE WHEN mistake_type = '?!' THEN 1 ELSE 0 END) as inaccuracies
                FROM tactics 
                WHERE LOWER(username) = LOWER(?)
            """
            cursor = await db.execute(query, (username,))
        
        row = await cursor.fetchone()
        
        return UserStats(
            username=username,
            platform=platform or "all",
            total_tactics=row["total"] or 0,
            blunders=row["blunders"] or 0,
            mistakes=row["mistakes"] or 0,
            inaccuracies=row["inaccuracies"] or 0,
        )

@app.post("/api/tactics", response_model=dict)
async def upload_tactics(
    upload: TacticsUpload,
    user: dict = Depends(verify_google_token),
):
    """
    Upload tactics from analyzed games. REQUIRES Google authentication.
    This prevents abuse - only authenticated users can upload.
    """
    async with aiosqlite.connect(DATABASE_PATH) as db:
        inserted = 0
        skipped = 0
        
        for tactic in upload.tactics:
            try:
                await db.execute("""
                    INSERT INTO tactics (
                        username, platform, fen, user_move, correct_line,
                        mistake_type, mistake_analysis, position_context,
                        game_white, game_black, game_result, game_date,
                        game_id, game_url, difficulty, created_at, uploader_email
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    upload.username,
                    upload.platform,
                    tactic.fen,
                    tactic.user_move,
                    json.dumps(tactic.correct_line),
                    tactic.mistake_type,
                    tactic.mistake_analysis,
                    tactic.position_context,
                    tactic.game_white,
                    tactic.game_black,
                    tactic.game_result,
                    tactic.game_date,
                    tactic.game_id,
                    tactic.game_url,
                    tactic.difficulty,
                    datetime.utcnow().isoformat(),
                    user["email"],
                ))
                inserted += 1
            except aiosqlite.IntegrityError:
                # Duplicate - skip
                skipped += 1
        
        await db.commit()
        
        return {
            "success": True,
            "inserted": inserted,
            "skipped": skipped,
            "message": f"Uploaded {inserted} new tactics ({skipped} duplicates skipped)",
        }

@app.delete("/api/tactics/{username}")
async def delete_user_tactics(
    username: str,
    platform: Optional[str] = Query(None),
    user: dict = Depends(verify_google_token),
):
    """
    Delete all tactics for a username. Requires auth.
    Only the uploader (by email match) can delete their tactics.
    """
    async with aiosqlite.connect(DATABASE_PATH) as db:
        if platform:
            result = await db.execute("""
                DELETE FROM tactics 
                WHERE LOWER(username) = LOWER(?) AND platform = ? AND uploader_email = ?
            """, (username, platform, user["email"]))
        else:
            result = await db.execute("""
                DELETE FROM tactics 
                WHERE LOWER(username) = LOWER(?) AND uploader_email = ?
            """, (username, user["email"]))
        
        await db.commit()
        deleted = result.rowcount
        
        return {"success": True, "deleted": deleted}

# --- Run ---

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

