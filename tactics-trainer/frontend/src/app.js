import { StockfishEngine } from './stockfish-wrapper';
import { Board as ChessBoard } from './chessboard';

// Win chance formula (from Lichess)
function calculateWinChance(centipawns) {
  return 50 + 50 * (2 / (1 + Math.exp(-0.00368208 * centipawns)) - 1);
}

export function tacticsApp() {
  return {
    // UI State
    training: false,
    settingsOpen: false,
    loading: false,
    status: '',
    statusType: '',
    message: 'Find the best move',
    messageClass: '',
    
    // Form State
    lichessUser: localStorage.getItem('lichessUser') || '',
    chesscomUser: localStorage.getItem('chesscomUser') || '',
    numGames: parseInt(localStorage.getItem('numGames')) || 20,
    tacticsFound: 0,
    
    // Time Controls
    timeControls: [
      { id: 'bullet', name: 'Bullet', enabled: false },
      { id: 'blitz', name: 'Blitz', enabled: true },
      { id: 'rapid', name: 'Rapid', enabled: true },
      { id: 'classical', name: 'Classical', enabled: true },
      { id: 'daily', name: 'Daily', enabled: true },
    ],
    
    // Training State
    tactics: [],
    currentIndex: 0,
    solved: false,
    solutionShown: false,
    autoNext: localStorage.getItem('autoNext') === 'true',
    board: null,
    
    // Engine
    stockfish: null,
    
    // Auth (placeholder)
    user: null,
    
    get currentTactic() {
      return this.tactics[this.currentIndex] || null;
    },
    
    get badgeClass() {
      const type = this.currentTactic?.mistake_type;
      if (type === '??') return 'blunder';
      if (type === '?') return 'mistake';
      return '';
    },
    
    init() {
      const saved = localStorage.getItem('timeControls');
      if (saved) {
        try {
          const parsed = JSON.parse(saved);
          this.timeControls.forEach(tc => {
            if (parsed[tc.id] !== undefined) tc.enabled = parsed[tc.id];
          });
        } catch (e) {}
      }
      this.$watch('timeControls', () => this.saveTimeControls(), { deep: true });
      this.$watch('autoNext', (val) => localStorage.setItem('autoNext', val.toString()));
    },
    
    saveTimeControls() {
      const obj = {};
      this.timeControls.forEach(tc => obj[tc.id] = tc.enabled);
      localStorage.setItem('timeControls', JSON.stringify(obj));
    },
    
    // ========== MAIN FLOW ==========
    async loadTactics() {
      const lichess = this.lichessUser.trim();
      const chesscom = this.chesscomUser.trim();
      
      if (!lichess && !chesscom) {
        this.setStatus('Enter at least one username', 'error');
        return;
      }
      
      if (lichess) localStorage.setItem('lichessUser', lichess);
      if (chesscom) localStorage.setItem('chesscomUser', chesscom);
      localStorage.setItem('numGames', this.numGames.toString());
      
      this.settingsOpen = false;
      this.loading = true;
      this.tactics = [];
      this.tacticsFound = 0;
      
      try {
        this.setStatus('Loading engine...');
        if (!this.stockfish) {
          this.stockfish = new StockfishEngine();
        }
        await this.stockfish.init();
        
        const enabledTypes = this.getEnabledPerfTypes();
        
        if (lichess) {
          await this.processLichessGames(lichess, enabledTypes);
        }
        
        if (chesscom) {
          await this.processChesscomGames(chesscom, enabledTypes);
        }
        
        if (this.tactics.length === 0) {
          this.setStatus('No mistakes found in your recent games!', 'success');
          this.loading = false;
          return;
        }
        
        this.tactics = this.shuffle(this.tactics);
        
        this.currentIndex = 0;
        this.training = true;
        this.setStatus('');

        await this.$nextTick();
        await this.initBoard();
        this.loadCurrentTactic();

      } catch (e) {
        console.error('Error:', e);
        this.setStatus(`Error: ${e.message}`, 'error');
      } finally {
        this.loading = false;
      }
    },
    
    // ========== LICHESS ==========
    async processLichessGames(username, enabledTypes) {
      this.setStatus('Downloading Lichess games...');
      
      const perfTypes = [];
      if (enabledTypes.includes('bullet')) perfTypes.push('bullet', 'ultraBullet');
      if (enabledTypes.includes('blitz')) perfTypes.push('blitz');
      if (enabledTypes.includes('rapid')) perfTypes.push('rapid');
      if (enabledTypes.includes('classical')) perfTypes.push('classical');
      if (enabledTypes.includes('correspondence')) perfTypes.push('correspondence');
      
      const since = Date.now() - (90 * 24 * 60 * 60 * 1000);
      const params = new URLSearchParams({
        since: since.toString(),
        perfType: perfTypes.join(','),
        moves: 'true',
        max: this.numGames.toString()
      });
      
      try {
        const res = await fetch(`https://lichess.org/api/games/user/${username}?${params}`, {
          headers: { 'Accept': 'application/x-chess-pgn' }
        });
        
        if (!res.ok) {
          console.warn('Lichess API error:', res.status);
          return;
        }
        
        const pgn = await res.text();
        const games = this.splitPgn(pgn);
        
        for (let i = 0; i < games.length; i++) {
          this.setStatus(`Analyzing Lichess game ${i + 1}/${games.length}...`);
          const newTactics = await this.analyzeGame(games[i], username);
          this.tactics.push(...newTactics);
          this.tacticsFound = this.tactics.length;
        }
      } catch (e) {
        console.warn('Lichess fetch error:', e);
      }
    },
    
    // ========== CHESS.COM ==========
    async processChesscomGames(username, enabledTypes) {
      this.setStatus('Downloading Chess.com games...');
      
      const now = new Date();
      const games = [];
      
      for (let i = 0; i < 3 && games.length < this.numGames; i++) {
        const year = now.getFullYear();
        const month = String(now.getMonth() + 1).padStart(2, '0');
        
        try {
          const res = await fetch(`https://api.chess.com/pub/player/${username.toLowerCase()}/games/${year}/${month}/pgn`);
          if (res.ok) {
            const pgn = await res.text();
            const monthGames = this.splitPgn(pgn);
            
            for (const game of monthGames) {
              if (games.length >= this.numGames) break;
              if (this.matchesTimeControl(game, enabledTypes)) {
                games.push(game);
              }
            }
          }
        } catch (e) {
          console.warn(`Chess.com error for ${year}/${month}:`, e);
        }
        
        now.setMonth(now.getMonth() - 1);
      }
      
      for (let i = 0; i < games.length; i++) {
        this.setStatus(`Analyzing Chess.com game ${i + 1}/${games.length}...`);
        const newTactics = await this.analyzeGame(games[i], username);
        this.tactics.push(...newTactics);
        this.tacticsFound = this.tactics.length;
      }
    },
    
    // ========== PGN PARSING ==========
    splitPgn(pgn) {
      if (!pgn?.trim()) return [];
      const games = [];
      let current = [];
      
      for (const line of pgn.split('\n')) {
        if (line.startsWith('[Event ') && current.length > 0) {
          games.push(current.join('\n'));
          current = [];
        }
        current.push(line);
      }
      if (current.length > 0) games.push(current.join('\n'));
      return games;
    },
    
    matchesTimeControl(pgn, enabledTypes) {
      const match = pgn.match(/\[TimeControl "([^"]+)"\]/);
      if (!match) return true;
      
      const tc = match[1];
      if (tc === '-') return enabledTypes.includes('correspondence');
      
      const parts = tc.split('+');
      const base = parseInt(parts[0]) || 0;
      const inc = parseInt(parts[1]) || 0;
      const total = base + 40 * inc;
      
      if (total < 180) return enabledTypes.includes('bullet');
      if (total < 600) return enabledTypes.includes('blitz');
      if (total < 1800) return enabledTypes.includes('rapid');
      return enabledTypes.includes('classical');
    },
    
    // ========== ANALYSIS ==========
    async analyzeGame(pgn, username) {
      const userLower = username.toLowerCase();
      
      const headers = {};
      for (const match of pgn.matchAll(/\[(\w+)\s+"([^"]*)"\]/g)) {
        headers[match[1]] = match[2];
      }
      
      console.log('='.repeat(80));
      console.log(`Analyzing: ${headers.White} vs ${headers.Black}`);
      console.log('='.repeat(80));
      
      const white = (headers.White || '').toLowerCase();
      const black = (headers.Black || '').toLowerCase();
      let userColor = null;
      if (white.includes(userLower)) userColor = 'w';
      else if (black.includes(userLower)) userColor = 'b';
      else return [];
      
      console.log(`User plays: ${userColor === 'w' ? 'White' : 'Black'}`);
      
      const movesMatch = pgn.match(/\n\n([\s\S]+)$/);
      if (!movesMatch) return [];
      
      const movesText = movesMatch[1]
        .replace(/\{[^}]*\}/g, '')
        .replace(/\([^)]*\)/g, '')
        .replace(/\$\d+/g, '')
        .replace(/\d+\.\.\./g, '')
        .trim();
      
      const moves = [];
      for (const m of movesText.matchAll(/(\d+)\.\s*(\S+)(?:\s+(\S+))?/g)) {
        const num = parseInt(m[1]);
        if (m[2] && !this.isResult(m[2])) moves.push({ num, san: m[2], color: 'w' });
        if (m[3] && !this.isResult(m[3])) moves.push({ num, san: m[3], color: 'b' });
      }
      
      const tactics = [];
      const game = new window.Chess.Game();
      const DEPTH = 15; // Match Flutter's depth
      
      console.log(`Total moves: ${moves.length}, analyzing at depth ${DEPTH}`);
      console.log('');
      
      for (const move of moves) {
        const isUserMove = move.color === userColor;
        
        if (!isUserMove) {
          const uci = this.findUci(game, move.san);
          if (uci) game.moveUci(uci);
          continue;
        }
        
        const fenBefore = game.getFen();
        const isWhiteTurnBefore = fenBefore.split(' ')[1] === 'w';
        const evalBefore = await this.stockfish.analyze(fenBefore, DEPTH);
        
        const uci = this.findUci(game, move.san);
        if (!uci) continue;
        game.moveUci(uci);
        
        const fenAfter = game.getFen();
        const isWhiteTurnAfter = fenAfter.split(' ')[1] === 'w';
        const evalAfter = await this.stockfish.analyze(fenAfter, DEPTH);
        
        // Raw evals from engine (in pawns, need to multiply by 100 for centipawns)
        const rawCpBefore = (evalBefore.eval || 0) * 100;
        const rawCpAfter = (evalAfter.eval || 0) * 100;
        
        // Normalize to White's perspective first (like Flutter's StockfishService does)
        let cpBeforeWhitePerspective = isWhiteTurnBefore ? rawCpBefore : -rawCpBefore;
        let cpAfterWhitePerspective = isWhiteTurnAfter ? rawCpAfter : -rawCpAfter;
        
        // Now normalize to USER's perspective
        let cpBefore = cpBeforeWhitePerspective;
        let cpAfter = cpAfterWhitePerspective;
        if (userColor === 'b') {
          cpBefore = -cpBeforeWhitePerspective;
          cpAfter = -cpAfterWhitePerspective;
        }
        
        const wcBefore = calculateWinChance(cpBefore);
        const wcAfter = calculateWinChance(cpAfter);
        const delta = wcBefore - wcAfter;
        
        const isBlunder = delta > 30;
        const isMistake = delta > 20 && delta <= 30;
        const status = isBlunder ? '⚠️ BLUNDER' : (isMistake ? '⚠ MISTAKE' : '✓ OK');
        
        // Log like Flutter does
        console.log(`--- Move ${move.num}. ${move.san} (${move.color === 'w' ? 'White' : 'Black'}) ---`);
        console.log(`FEN: ${fenBefore}`);
        console.log(`Raw eval before: ${rawCpBefore.toFixed(0)}cp, after: ${rawCpAfter.toFixed(0)}cp`);
        console.log(`Eval Before: ${cpBefore.toFixed(0)}cp (${wcBefore.toFixed(1)}%)`);
        console.log(`Eval After:  ${cpAfter.toFixed(0)}cp (${wcAfter.toFixed(1)}%)`);
        console.log(`Delta: ${delta.toFixed(1)}% | ${status}`);
        console.log(`PV: ${(evalBefore.pv || []).slice(0, 3).join(' ')}`);
        console.log('');
        
        if (delta > 20) {
          tactics.push({
            fen: fenBefore,
            user_move: move.san,
            correct_line: evalBefore.pv?.slice(0, 3) || [],
            mistake_type: isBlunder ? '??' : '?',
            mistake_analysis: `${isBlunder ? 'Blunder' : 'Mistake'}: ${wcBefore.toFixed(0)}% → ${wcAfter.toFixed(0)}%`,
            position_context: `Move ${move.num}, ${userColor === 'w' ? 'White' : 'Black'} to play`,
            game_url: headers.Link || headers.Site || '',
            game_white: headers.White || '',
            game_black: headers.Black || '',
          });
        }
      }
      
      console.log('='.repeat(80));
      console.log(`Analysis complete. Found ${tactics.length} tactics.`);
      console.log('='.repeat(80));
      
      return tactics;
    },
    
    isResult(s) {
      return ['1-0', '0-1', '1/2-1/2', '*'].includes(s);
    },
    
    findUci(game, san) {
      const clean = san.replace(/[+#!?=]/g, '');
      
      for (let sq = 0; sq < 64; sq++) {
        const piece = game.board[sq];
        if (!piece || piece.color !== game.turn) continue;
        
        const moves = game.getLegalMoves(sq);
        for (const m of moves) {
          if (this.matchesSan(game, m, clean)) {
            return m.fromAlg + m.toAlg + (m.promotion || '');
          }
        }
      }
      return null;
    },
    
    matchesSan(game, move, san) {
      const piece = game.board[move.from];
      if (!piece) return false;
      
      if (san === 'O-O' || san === 'O-O-O') {
        return move.castling === (san === 'O-O' ? (piece.color === 'w' ? 'K' : 'k') : (piece.color === 'w' ? 'Q' : 'q'));
      }
      
      if (piece.type === 'p') {
        if (san.includes('x')) {
          return san[0] === move.fromAlg[0] && san.slice(-2) === move.toAlg;
        }
        return san === move.toAlg || san.startsWith(move.toAlg);
      }
      
      const pieceChar = piece.type.toUpperCase();
      if (!san.startsWith(pieceChar)) return false;
      
      const dest = san.slice(-2);
      return dest === move.toAlg;
    },
    
    getEnabledPerfTypes() {
      const types = [];
      this.timeControls.forEach(tc => {
        if (!tc.enabled) return;
        if (tc.id === 'bullet') types.push('bullet');
        if (tc.id === 'blitz') types.push('blitz');
        if (tc.id === 'rapid') types.push('rapid');
        if (tc.id === 'classical') types.push('classical');
        if (tc.id === 'daily') types.push('correspondence');
      });
      return types;
    },
    
    shuffle(arr) {
      const a = [...arr];
      for (let i = a.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [a[i], a[j]] = [a[j], a[i]];
      }
      return a;
    },
    
    // ========== TRAINING UI ==========
    async initBoard() {
      if (!this.board) {
        this.board = new ChessBoard('board', {
          interactive: true,
          onMove: (uci) => this.handleMove(uci)
        });
      }
      await this.board.mount();
    },
    
    loadCurrentTactic() {
      const t = this.currentTactic;
      if (!t) return;
      
      this.solved = false;
      this.solutionShown = false;
      this.setMessage('', '');
      
      const isBlack = t.position_context?.includes('Black');
      this.board.setFlipped(isBlack);
      this.board.setPosition(t.fen);
      this.board.setInteractive(true);
    },
    
    handleMove(uci) {
      if (this.solved) return;
      
      const correct = this.currentTactic?.correct_line?.[0]?.toLowerCase() || '';
      const played = uci.toLowerCase();
      
      if (played === correct || correct.startsWith(played) || played.startsWith(correct)) {
        this.solved = true;
        this.setMessage('', 'correct');
        this.board.setInteractive(false);
        
        // Auto-next after delay
        if (this.autoNext) {
          setTimeout(() => this.nextTactic(), 1200);
        }
      } else {
        this.setMessage('Try again', 'incorrect');
        setTimeout(() => {
          this.board.setPosition(this.currentTactic.fen);
          this.setMessage('', '');
        }, 800);
      }
    },
    
    showSolution() {
      this.solutionShown = true;
      // Keep board interactive - user should still play the move
    },
    
    // Convert UCI line to SAN for display
    getSolutionSan() {
      const t = this.currentTactic;
      if (!t || !t.correct_line?.length) return '?';
      return this.convertUciLineToSan(t.fen, t.correct_line).join(' ');
    },
    
    convertUciLineToSan(fen, uciMoves) {
      if (!fen || !uciMoves?.length) return uciMoves || [];
      
      try {
        const game = new window.Chess.Game(fen);
        const sanMoves = [];
        
        for (const uci of uciMoves) {
          const san = this.uciToSan(game, uci);
          if (san) {
            sanMoves.push(san);
            game.moveUci(uci);
          } else {
            sanMoves.push(uci);
          }
        }
        return sanMoves;
      } catch (e) {
        console.warn('Failed to convert UCI to SAN:', e);
        return uciMoves;
      }
    },
    
    uciToSan(game, uci) {
      if (!uci || uci.length < 4) return null;
      
      const from = uci.substring(0, 2);
      const to = uci.substring(2, 4);
      const promo = uci.length > 4 ? uci[4] : null;
      
      const fromSq = game.algebraicToIndex(from);
      const toSq = game.algebraicToIndex(to);
      const piece = game.board[fromSq];
      
      if (!piece) return null;
      
      // Castling
      if (piece.type === 'k') {
        if (from === 'e1' && to === 'g1') return 'O-O';
        if (from === 'e1' && to === 'c1') return 'O-O-O';
        if (from === 'e8' && to === 'g8') return 'O-O';
        if (from === 'e8' && to === 'c8') return 'O-O-O';
      }
      
      const captured = game.board[toSq];
      const isCapture = !!captured || (piece.type === 'p' && from[0] !== to[0]);
      
      let san = '';
      
      if (piece.type === 'p') {
        if (isCapture) {
          san = from[0] + 'x' + to;
        } else {
          san = to;
        }
        if (promo) {
          san += '=' + promo.toUpperCase();
        }
      } else {
        san = piece.type.toUpperCase();
        const disambig = this.getDisambiguation(game, piece, fromSq, toSq);
        san += disambig;
        if (isCapture) san += 'x';
        san += to;
      }
      
      return san;
    },
    
    getDisambiguation(game, piece, fromSq, toSq) {
      const others = [];
      for (let sq = 0; sq < 64; sq++) {
        if (sq === fromSq) continue;
        const p = game.board[sq];
        if (!p || p.type !== piece.type || p.color !== piece.color) continue;
        
        const moves = game.getLegalMoves(sq);
        if (moves.some(m => m.to === toSq)) {
          others.push(sq);
        }
      }
      
      if (others.length === 0) return '';
      
      const fromAlg = game.indexToAlgebraic(fromSq);
      const fromFile = fromAlg[0];
      const fromRank = fromAlg[1];
      
      const sameFile = others.some(sq => game.indexToAlgebraic(sq)[0] === fromFile);
      const sameRank = others.some(sq => game.indexToAlgebraic(sq)[1] === fromRank);
      
      if (!sameFile) return fromFile;
      if (!sameRank) return fromRank;
      return fromFile + fromRank;
    },
    
    prevTactic() {
      if (this.currentIndex > 0) {
        this.currentIndex--;
        this.loadCurrentTactic();
      }
    },
    
    nextTactic() {
      if (this.currentIndex < this.tactics.length - 1) {
        this.currentIndex++;
        this.loadCurrentTactic();
      } else {
        this.setMessage('All done!', 'correct');
      }
    },
    
    openAnalysis() {
      const url = this.currentTactic?.game_url;
      if (url) {
        // For Chess.com links, we can analyze on Lichess via import
        if (url.includes('chess.com')) {
          // Open on Lichess analysis with FEN
          const fen = encodeURIComponent(this.currentTactic.fen);
          window.open(`https://lichess.org/analysis/${fen.replace(/%20/g, '_')}`, '_blank');
        } else {
          // Lichess game link - just open it
          window.open(url, '_blank');
        }
      }
    },
    
    backToSetup() {
      this.training = false;
      this.tactics = [];
      this.currentIndex = 0;
    },
    
    signOut() {
      this.user = null;
    },
    
    setStatus(text, type = '') {
      this.status = text;
      this.statusType = type;
    },
    
    setMessage(text, type = '') {
      this.message = text;
      this.messageClass = type;
    }
  };
}

