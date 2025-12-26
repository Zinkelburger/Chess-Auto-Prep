#!/usr/bin/env node
/**
 * Standalone Node.js test script for tactics analysis comparison
 * Run with: node test_js_analysis.mjs
 * 
 * This uses the same logic as the web app but outputs detailed logs
 * for comparison with the Flutter version.
 */

import { spawn } from 'child_process';
import { existsSync } from 'fs';

const USERNAME = 'bigmanarkhangelsk';
const DEPTH = 15;

// Win% formula (same as Flutter and JS web)
function calculateWinChance(centipawns) {
  return 50 + 50 * (2 / (1 + Math.exp(-0.00368208 * centipawns)) - 1);
}

// Simple UCI engine wrapper
class SimpleStockfish {
  constructor() {
    this.process = null;
    this.ready = false;
    this.buffer = '';
    this.resolver = null;
  }
  
  async init() {
    const paths = [
      '/usr/bin/stockfish',
      '/usr/local/bin/stockfish',
      'stockfish',
    ];
    
    let stockfishPath = null;
    for (const p of paths) {
      if (existsSync(p) || p === 'stockfish') {
        stockfishPath = p;
        break;
      }
    }
    
    if (!stockfishPath) {
      throw new Error('Stockfish not found');
    }
    
    return new Promise((resolve, reject) => {
      this.process = spawn(stockfishPath);
      
      this.process.stdout.on('data', (data) => {
        this.buffer += data.toString();
        this.processBuffer();
      });
      
      this.process.stderr.on('data', (data) => {
        console.error('Stockfish stderr:', data.toString());
      });
      
      this.process.on('error', reject);
      
      // Initialize UCI
      this.process.stdin.write('uci\n');
      
      setTimeout(() => {
        this.process.stdin.write('isready\n');
        setTimeout(() => {
          this.ready = true;
          console.log('[Stockfish] Ready');
          resolve();
        }, 500);
      }, 500);
    });
  }
  
  processBuffer() {
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() || '';
    
    for (const line of lines) {
      if (this.resolver && line.startsWith('bestmove')) {
        this.resolver.onBestMove(line);
      } else if (this.resolver && line.startsWith('info depth') && line.includes(' pv ')) {
        this.resolver.onInfo(line);
      }
    }
  }
  
  async getEvaluation(fen, depth = 15) {
    if (!this.ready) throw new Error('Engine not ready');
    
    const isWhiteTurn = fen.split(' ')[1] === 'w';
    
    return new Promise((resolve) => {
      let scoreCp = null;
      let scoreMate = null;
      let pv = [];
      
      this.resolver = {
        onInfo: (line) => {
          const cpMatch = line.match(/score cp (-?\d+)/);
          const mateMatch = line.match(/score mate (-?\d+)/);
          const pvMatch = line.match(/ pv (.+)/);
          
          if (cpMatch) {
            const rawCp = parseInt(cpMatch[1]);
            // Normalize to White's perspective (like Flutter StockfishService)
            scoreCp = isWhiteTurn ? rawCp : -rawCp;
          } else if (mateMatch) {
            const rawMate = parseInt(mateMatch[1]);
            scoreMate = isWhiteTurn ? rawMate : -rawMate;
          }
          
          if (pvMatch) {
            pv = pvMatch[1].split(' ');
          }
        },
        onBestMove: () => {
          this.resolver = null;
          
          let effectiveCp;
          if (scoreMate !== null) {
            effectiveCp = scoreMate > 0 ? 10000 : -10000;
          } else {
            effectiveCp = scoreCp || 0;
          }
          
          resolve({
            scoreCp,
            scoreMate,
            effectiveCp,
            pv,
          });
        }
      };
      
      this.process.stdin.write('ucinewgame\n');
      this.process.stdin.write(`position fen ${fen}\n`);
      this.process.stdin.write(`go depth ${depth}\n`);
    });
  }
  
  dispose() {
    if (this.process) {
      this.process.stdin.write('quit\n');
      this.process.kill();
    }
  }
}

// Simple chess position tracker
class SimpleChess {
  constructor() {
    this.reset();
  }
  
  reset() {
    // Board representation: array of 64 squares (a1=0, h8=63)
    // Each square is null or {type: 'p'|'n'|'b'|'r'|'q'|'k', color: 'w'|'b'}
    this.board = new Array(64).fill(null);
    this.turn = 'w';
    this.castling = { K: true, Q: true, k: true, q: true };
    this.epSquare = null;
    this.halfmove = 0;
    this.fullmove = 1;
    
    // Setup initial position
    const backRank = ['r', 'n', 'b', 'q', 'k', 'b', 'n', 'r'];
    for (let i = 0; i < 8; i++) {
      this.board[i] = { type: backRank[i], color: 'w' };
      this.board[i + 8] = { type: 'p', color: 'w' };
      this.board[i + 48] = { type: 'p', color: 'b' };
      this.board[i + 56] = { type: backRank[i], color: 'b' };
    }
  }
  
  algebraicToIndex(sq) {
    const file = sq.charCodeAt(0) - 'a'.charCodeAt(0);
    const rank = parseInt(sq[1]) - 1;
    return rank * 8 + file;
  }
  
  indexToAlgebraic(idx) {
    const file = String.fromCharCode('a'.charCodeAt(0) + (idx % 8));
    const rank = Math.floor(idx / 8) + 1;
    return `${file}${rank}`;
  }
  
  getFen() {
    let fen = '';
    
    for (let rank = 7; rank >= 0; rank--) {
      let empty = 0;
      for (let file = 0; file < 8; file++) {
        const piece = this.board[rank * 8 + file];
        if (piece === null) {
          empty++;
        } else {
          if (empty > 0) {
            fen += empty;
            empty = 0;
          }
          const c = piece.type;
          fen += piece.color === 'w' ? c.toUpperCase() : c;
        }
      }
      if (empty > 0) fen += empty;
      if (rank > 0) fen += '/';
    }
    
    fen += ` ${this.turn}`;
    
    let castleStr = '';
    if (this.castling.K) castleStr += 'K';
    if (this.castling.Q) castleStr += 'Q';
    if (this.castling.k) castleStr += 'k';
    if (this.castling.q) castleStr += 'q';
    fen += ` ${castleStr || '-'}`;
    
    fen += ` ${this.epSquare || '-'}`;
    fen += ` ${this.halfmove}`;
    fen += ` ${this.fullmove}`;
    
    return fen;
  }
  
  move(san) {
    // Parse SAN and make move
    // This is a simplified parser - handles common cases
    
    let s = san.replace(/[+#!?]/g, '');
    
    // Castling
    if (s === 'O-O' || s === '0-0') {
      const rank = this.turn === 'w' ? 0 : 7;
      const kingFrom = rank * 8 + 4;
      const kingTo = rank * 8 + 6;
      const rookFrom = rank * 8 + 7;
      const rookTo = rank * 8 + 5;
      
      this.board[kingTo] = this.board[kingFrom];
      this.board[kingFrom] = null;
      this.board[rookTo] = this.board[rookFrom];
      this.board[rookFrom] = null;
      
      if (this.turn === 'w') {
        this.castling.K = false;
        this.castling.Q = false;
      } else {
        this.castling.k = false;
        this.castling.q = false;
      }
      
      this.finishMove();
      return true;
    }
    
    if (s === 'O-O-O' || s === '0-0-0') {
      const rank = this.turn === 'w' ? 0 : 7;
      const kingFrom = rank * 8 + 4;
      const kingTo = rank * 8 + 2;
      const rookFrom = rank * 8 + 0;
      const rookTo = rank * 8 + 3;
      
      this.board[kingTo] = this.board[kingFrom];
      this.board[kingFrom] = null;
      this.board[rookTo] = this.board[rookFrom];
      this.board[rookFrom] = null;
      
      if (this.turn === 'w') {
        this.castling.K = false;
        this.castling.Q = false;
      } else {
        this.castling.k = false;
        this.castling.q = false;
      }
      
      this.finishMove();
      return true;
    }
    
    // Extract promotion
    let promotion = null;
    const promoMatch = s.match(/[=]?([QRBN])$/i);
    if (promoMatch) {
      promotion = promoMatch[1].toLowerCase();
      s = s.replace(/[=]?[QRBN]$/i, '');
    }
    
    // Destination (last 2 chars)
    const dest = s.slice(-2);
    const destIdx = this.algebraicToIndex(dest);
    s = s.slice(0, -2);
    
    // Capture marker
    const isCapture = s.includes('x');
    s = s.replace('x', '');
    
    // Piece type
    let pieceType = 'p';
    if (s.length > 0 && /^[KQRBN]$/.test(s[0])) {
      pieceType = s[0].toLowerCase();
      s = s.slice(1);
    }
    
    // Disambiguation
    let disambigFile = null;
    let disambigRank = null;
    if (s.length === 1) {
      if (/[a-h]/.test(s)) disambigFile = s;
      else if (/[1-8]/.test(s)) disambigRank = s;
    } else if (s.length === 2) {
      disambigFile = s[0];
      disambigRank = s[1];
    }
    
    // For pawn captures, need the source file
    if (pieceType === 'p' && isCapture && !disambigFile) {
      const cleanSan = san.replace(/[+#!?]/g, '').replace(/[=]?[QRBN]$/i, '');
      const xIdx = cleanSan.indexOf('x');
      if (xIdx > 0) {
        disambigFile = cleanSan[xIdx - 1];
      }
    }
    
    // Find the piece
    let fromIdx = null;
    for (let i = 0; i < 64; i++) {
      const piece = this.board[i];
      if (!piece || piece.color !== this.turn || piece.type !== pieceType) continue;
      
      const alg = this.indexToAlgebraic(i);
      if (disambigFile && alg[0] !== disambigFile) continue;
      if (disambigRank && alg[1] !== disambigRank) continue;
      
      // Check if this piece can reach destination
      if (this.canMove(i, destIdx, pieceType)) {
        fromIdx = i;
        break;
      }
    }
    
    if (fromIdx === null) {
      console.error(`Could not find piece for move: ${san}`);
      return false;
    }
    
    // Handle en passant capture
    if (pieceType === 'p' && isCapture && this.board[destIdx] === null) {
      // En passant - remove the captured pawn
      const capturedIdx = destIdx + (this.turn === 'w' ? -8 : 8);
      this.board[capturedIdx] = null;
    }
    
    // Make the move
    this.board[destIdx] = this.board[fromIdx];
    this.board[fromIdx] = null;
    
    // Handle promotion
    if (promotion) {
      this.board[destIdx] = { type: promotion, color: this.turn };
    }
    
    // Update en passant square
    if (pieceType === 'p' && Math.abs(destIdx - fromIdx) === 16) {
      this.epSquare = this.indexToAlgebraic((fromIdx + destIdx) / 2);
    } else {
      this.epSquare = null;
    }
    
    // Update castling rights
    if (pieceType === 'k') {
      if (this.turn === 'w') {
        this.castling.K = false;
        this.castling.Q = false;
      } else {
        this.castling.k = false;
        this.castling.q = false;
      }
    }
    if (pieceType === 'r') {
      const alg = this.indexToAlgebraic(fromIdx);
      if (alg === 'a1') this.castling.Q = false;
      if (alg === 'h1') this.castling.K = false;
      if (alg === 'a8') this.castling.q = false;
      if (alg === 'h8') this.castling.k = false;
    }
    
    this.finishMove();
    return true;
  }
  
  canMove(from, to, pieceType) {
    const fromFile = from % 8;
    const fromRank = Math.floor(from / 8);
    const toFile = to % 8;
    const toRank = Math.floor(to / 8);
    const dFile = toFile - fromFile;
    const dRank = toRank - fromRank;
    
    switch (pieceType) {
      case 'p':
        const dir = this.turn === 'w' ? 1 : -1;
        const startRank = this.turn === 'w' ? 1 : 6;
        
        // Forward move
        if (dFile === 0 && dRank === dir && !this.board[to]) return true;
        // Double push from start
        if (dFile === 0 && dRank === 2 * dir && fromRank === startRank && 
            !this.board[to] && !this.board[from + 8 * dir]) return true;
        // Capture
        if (Math.abs(dFile) === 1 && dRank === dir) {
          if (this.board[to] || this.indexToAlgebraic(to) === this.epSquare) return true;
        }
        return false;
        
      case 'n':
        return (Math.abs(dFile) === 2 && Math.abs(dRank) === 1) ||
               (Math.abs(dFile) === 1 && Math.abs(dRank) === 2);
        
      case 'b':
        if (Math.abs(dFile) !== Math.abs(dRank)) return false;
        return this.isPathClear(from, to, Math.sign(dFile), Math.sign(dRank));
        
      case 'r':
        if (dFile !== 0 && dRank !== 0) return false;
        return this.isPathClear(from, to, Math.sign(dFile), Math.sign(dRank));
        
      case 'q':
        if (dFile !== 0 && dRank !== 0 && Math.abs(dFile) !== Math.abs(dRank)) return false;
        return this.isPathClear(from, to, Math.sign(dFile), Math.sign(dRank));
        
      case 'k':
        return Math.abs(dFile) <= 1 && Math.abs(dRank) <= 1;
    }
    
    return false;
  }
  
  isPathClear(from, to, dFile, dRank) {
    let current = from + dFile + dRank * 8;
    while (current !== to) {
      if (this.board[current]) return false;
      current += dFile + dRank * 8;
    }
    return true;
  }
  
  finishMove() {
    if (this.turn === 'b') {
      this.fullmove++;
    }
    this.turn = this.turn === 'w' ? 'b' : 'w';
  }
}

async function main() {
  console.log('='.repeat(80));
  console.log('JAVASCRIPT TACTICS ANALYSIS TEST');
  console.log(`Username: ${USERNAME}`);
  console.log(`Depth: ${DEPTH}`);
  console.log('='.repeat(80));
  console.log('');
  
  // Download 1 game from Chess.com
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  
  console.log('Downloading games from Chess.com...');
  
  let pgn;
  try {
    let url = `https://api.chess.com/pub/player/${USERNAME.toLowerCase()}/games/${year}/${month}/pgn`;
    let response = await fetch(url);
    
    if (!response.ok) {
      // Try previous month
      const prevDate = new Date(now);
      prevDate.setMonth(prevDate.getMonth() - 1);
      const prevYear = prevDate.getFullYear();
      const prevMonth = String(prevDate.getMonth() + 1).padStart(2, '0');
      url = `https://api.chess.com/pub/player/${USERNAME.toLowerCase()}/games/${prevYear}/${prevMonth}/pgn`;
      response = await fetch(url);
      
      if (!response.ok) {
        console.error('Failed to fetch games');
        process.exit(1);
      }
    }
    
    pgn = await response.text();
  } catch (e) {
    console.error('Error fetching games:', e);
    process.exit(1);
  }
  
  // Split PGN and get first game
  const games = [];
  let currentGame = [];
  
  for (const line of pgn.split('\n')) {
    if (line.startsWith('[Event ') && currentGame.length > 0) {
      games.push(currentGame.join('\n'));
      currentGame = [];
    }
    currentGame.push(line);
  }
  if (currentGame.length > 0) {
    games.push(currentGame.join('\n'));
  }
  
  if (games.length === 0) {
    console.error('No games found');
    process.exit(1);
  }
  
  const gameText = games[0];
  console.log(`Found ${games.length} games, analyzing first one...`);
  console.log('');
  
  // Parse headers
  const headers = {};
  for (const match of gameText.matchAll(/\[(\w+)\s+"([^"]*)"\]/g)) {
    headers[match[1]] = match[2];
  }
  
  console.log(`Game: ${headers.White} vs ${headers.Black}`);
  console.log(`Date: ${headers.Date}`);
  console.log(`Result: ${headers.Result}`);
  console.log('');
  
  // Find user color
  const white = (headers.White || '').toLowerCase();
  const black = (headers.Black || '').toLowerCase();
  const userLower = USERNAME.toLowerCase();
  
  let userColor;
  if (white.includes(userLower)) {
    userColor = 'w';
  } else if (black.includes(userLower)) {
    userColor = 'b';
  } else {
    console.error('User not found in game');
    process.exit(1);
  }
  
  console.log(`User plays: ${userColor === 'w' ? 'White' : 'Black'}`);
  console.log('');
  
  // Extract moves
  const movesMatch = gameText.match(/\n\n([\s\S]+)$/);
  if (!movesMatch) {
    console.error('No moves found');
    process.exit(1);
  }
  
  const movesText = movesMatch[1]
    .replace(/\{[^}]*\}/g, '')
    .replace(/\([^)]*\)/g, '')
    .replace(/\$\d+/g, '')
    .replace(/\d+\.\.\./g, '')
    .trim();
  
  const moves = [];
  for (const m of movesText.matchAll(/(\d+)\.\s*(\S+)(?:\s+(\S+))?/g)) {
    const num = parseInt(m[1]);
    const whiteMove = m[2];
    const blackMove = m[3];
    
    if (!['1-0', '0-1', '1/2-1/2', '*'].includes(whiteMove)) {
      moves.push({ num, san: whiteMove, color: 'w' });
    }
    if (blackMove && !['1-0', '0-1', '1/2-1/2', '*'].includes(blackMove)) {
      moves.push({ num, san: blackMove, color: 'b' });
    }
  }
  
  console.log(`Total moves: ${moves.length}`);
  console.log('');
  
  // Initialize Stockfish
  console.log('Initializing Stockfish...');
  const stockfish = new SimpleStockfish();
  await stockfish.init();
  console.log('');
  
  // Replay game and analyze user moves
  const game = new SimpleChess();
  
  console.log('='.repeat(80));
  console.log('POSITION-BY-POSITION ANALYSIS');
  console.log('='.repeat(80));
  console.log('');
  
  for (const move of moves) {
    const { san, num, color } = move;
    const isUserMove = color === userColor;
    
    if (!isUserMove) {
      // Opponent's move - just play it
      const result = game.move(san);
      if (!result) {
        console.error(`ERROR: Failed to parse opponent move: ${san}`);
        break;
      }
      continue;
    }
    
    // User's move - analyze
    const fenBefore = game.getFen();
    
    console.log(`--- Move ${num}. ${san} (${color === 'w' ? 'White' : 'Black'}) ---`);
    console.log(`FEN: ${fenBefore}`);
    
    // Analyze position BEFORE the move
    const evalBefore = await stockfish.getEvaluation(fenBefore, DEPTH);
    
    // Make the move
    const result = game.move(san);
    if (!result) {
      console.error(`ERROR: Failed to parse user move: ${san}`);
      break;
    }
    
    const fenAfter = game.getFen();
    
    // Analyze position AFTER the move
    const evalAfter = await stockfish.getEvaluation(fenAfter, DEPTH);
    
    // Get effective centipawns (already normalized to White's perspective by engine wrapper)
    let cpBefore = evalBefore.effectiveCp;
    let cpAfter = evalAfter.effectiveCp;
    
    // Normalize to USER's perspective
    if (userColor === 'b') {
      cpBefore = -cpBefore;
      cpAfter = -cpAfter;
    }
    
    const winChanceBefore = calculateWinChance(cpBefore);
    const winChanceAfter = calculateWinChance(cpAfter);
    const delta = winChanceBefore - winChanceAfter;
    
    const isBlunder = delta > 30;
    const isMistake = delta > 20 && delta <= 30;
    const status = isBlunder ? '⚠️ BLUNDER' : (isMistake ? '⚠ MISTAKE' : '✓ OK');
    
    console.log(`Eval Before: ${cpBefore}cp (${winChanceBefore.toFixed(1)}%)`);
    console.log(`Eval After:  ${cpAfter}cp (${winChanceAfter.toFixed(1)}%)`);
    console.log(`Delta: ${delta.toFixed(1)}% | ${status}`);
    console.log(`PV: ${evalBefore.pv.slice(0, 3).join(' ')}`);
    console.log('');
  }
  
  console.log('='.repeat(80));
  console.log('ANALYSIS COMPLETE');
  console.log('='.repeat(80));
  
  stockfish.dispose();
}

main().catch(console.error);


