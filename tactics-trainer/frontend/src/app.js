import { StockfishEngine } from './stockfish-wrapper';
import { Board as ChessBoard } from './chessboard';

// Winning chances formula (from Lichess scalachess)
// Returns [-1, +1] where -1 = losing, 0 = equal, +1 = winning
// https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/eval.scala
const MULTIPLIER = -0.00368208;
function winningChances(centipawns) {
  const capped = Math.max(-1000, Math.min(1000, centipawns));
  return 2 / (1 + Math.exp(MULTIPLIER * capped)) - 1;
}

// Win percent for display purposes [0, 100]
function winPercent(centipawns) {
  return 50 + 50 * winningChances(centipawns);
}

export function tacticsApp() {
  return {
    // UI State
    training: false,
    settingsOpen: false,
    loading: false,
    hasStarted: false,  // true only after Load Tactics clicked
    status: '',
    statusType: '',
    message: '',
    messageClass: '',
    
    // Form State
    lichessUser: localStorage.getItem('lichessUser') || '',
    chesscomUser: localStorage.getItem('chesscomUser') || '',
    numGames: parseInt(localStorage.getItem('numGames')) || 20,
    analysisDepth: parseInt(localStorage.getItem('analysisDepth')) || 15,
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
    autoNext: localStorage.getItem('autoNext') !== 'false',  // default true
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
      localStorage.setItem('analysisDepth', this.analysisDepth.toString());
      
      this.settingsOpen = false;
      this.loading = true;
      this.tactics = [];
      this.tacticsFound = 0;
      this.gamesAnalyzed = 0;
      
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
        
        if (this.gamesAnalyzed === 0) {
          this.setStatus('No games found', 'error');
          this.loading = false;
          return;
        }
        
        if (this.tactics.length === 0) {
          this.setStatus('No mistakes found', '');
          this.loading = false;
          return;
        }
        
        // Keep tactics in chronological order (game by game, move by move)
        // Previously shuffled: this.tactics = this.shuffle(this.tactics);
        
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
      
      // Use only 'max' parameter to get last N games regardless of date
      // (removed 'since' filter which excluded games older than 90 days)
      const params = new URLSearchParams({
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
          this.gamesAnalyzed++;
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
        this.gamesAnalyzed++;
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
      const depth = Math.min(this.analysisDepth || 15, 25); // User-configurable, max 25
      
      console.log(`Total moves: ${moves.length}, analyzing at depth ${depth}`);
      console.log('');
      
      for (const move of moves) {
        const isUserMove = move.color === userColor;
        
        if (!isUserMove) {
          // Opponent's move - just play it using SAN directly
          const result = game.moveSan(move.san);
          if (!result) {
            console.warn(`Failed to play opponent move: ${move.san}`);
          }
          continue;
        }
        
        const fenBefore = game.getFen();
        const isWhiteTurnBefore = fenBefore.split(' ')[1] === 'w';
        const evalBefore = await this.stockfish.analyze(fenBefore, depth);
        
        // Play the user's move using SAN directly - library handles parsing
        const moveResult = game.moveSan(move.san);
        if (!moveResult) {
          console.warn(`Failed to play user move: ${move.san}`);
          continue;
        }
        
        // moveResult contains: { from, to, san, lan (UCI), before, after, ... }
        const uci = moveResult.lan || (moveResult.from + moveResult.to + (moveResult.promotion || ''));
        
        const fenAfter = game.getFen();
        const isWhiteTurnAfter = fenAfter.split(' ')[1] === 'w';
        const evalAfter = await this.stockfish.analyze(fenAfter, depth);
        
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
        
        // Use Lichess [-1, +1] scale for classification
        const wcBefore = winningChances(cpBefore);
        const wcAfter = winningChances(cpAfter);
        const delta = wcBefore - wcAfter;
        
        // Lichess thresholds (from lila/modules/tree/src/main/Advice.scala)
        // Blunder: >= 0.3, Mistake: >= 0.2, Inaccuracy: >= 0.1
        const isBlunder = delta >= 0.3;
        const isMistake = delta >= 0.2 && delta < 0.3;
        const status = isBlunder ? '⚠️ BLUNDER' : (isMistake ? '⚠ MISTAKE' : '✓ OK');
        
        // Use winPercent for display
        const wpBefore = winPercent(cpBefore);
        const wpAfter = winPercent(cpAfter);
        
        // Log like Flutter does
        console.log(`--- Move ${move.num}. ${move.san} (${move.color === 'w' ? 'White' : 'Black'}) ---`);
        console.log(`FEN: ${fenBefore}`);
        console.log(`Raw eval before: ${rawCpBefore.toFixed(0)}cp, after: ${rawCpAfter.toFixed(0)}cp`);
        console.log(`Eval Before: ${cpBefore.toFixed(0)}cp (${wpBefore.toFixed(1)}%)`);
        console.log(`Eval After:  ${cpAfter.toFixed(0)}cp (${wpAfter.toFixed(1)}%)`);
        console.log(`Delta: ${delta.toFixed(3)} (${(delta * 50).toFixed(1)}%) | ${status}`);
        console.log(`PV: ${(evalBefore.pv || []).slice(0, 3).join(' ')}`);
        console.log('');
        
        if (delta >= 0.2) {
          tactics.push({
            fen: fenBefore,
            user_move: move.san,
            correct_line: evalBefore.pv?.slice(0, 3) || [],
            mistake_type: isBlunder ? '??' : '?',
            mistake_analysis: `${isBlunder ? 'Blunder' : 'Mistake'}: ${wpBefore.toFixed(0)}% → ${wpAfter.toFixed(0)}%`,
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
        
        // Get the SAN notation for the correct move
        const correctSan = this.getFirstMoveSan();
        this.setMessage(`${correctSan} is correct`, 'correct');
        
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
    
    // Get SAN of the first correct move
    getFirstMoveSan() {
      const t = this.currentTactic;
      if (!t || !t.correct_line?.length) return '?';
      
      try {
        const game = new window.Chess.Game(t.fen);
        const san = game.getSan(t.correct_line[0]);
        return san || t.correct_line[0];
      } catch (e) {
        return t.correct_line[0];
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
      // Use library function - handles checks/mates/castling/disambiguation correctly
      if (game.getSan) {
        return game.getSan(uci);
      }
      // Fallback to raw UCI if getSan not available
      return uci;
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
      const fen = this.currentTactic?.fen;
      if (fen) {
        // Format FEN for Lichess: replace spaces with underscores, keep slashes
        const fenForUrl = fen.replace(/ /g, '_');
        // Determine color from FEN (second field is turn)
        const turn = fen.split(' ')[1];
        const color = turn === 'w' ? 'white' : 'black';
        window.open(`https://lichess.org/analysis?fen=${fenForUrl}&color=${color}`, '_blank');
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

