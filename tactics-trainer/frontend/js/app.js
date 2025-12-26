/**
 * Tactics Trainer - Alpine.js App
 * Download games → Analyze locally → Train
 */

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

function tacticsApp() {
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
    board: null,
    
    // Engine
    stockfish: null,
    
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
        // Step 1: Initialize engine
        this.setStatus('Loading engine...');
        if (!this.stockfish) {
          this.stockfish = new StockfishEngine();
        }
        await this.stockfish.init();
        
        // Step 2: Download and analyze games
        const enabledTypes = this.getEnabledPerfTypes();
        
        if (lichess) {
          await this.processLichessGames(lichess, enabledTypes);
        }
        
        if (chesscom) {
          await this.processChesscomGames(chesscom, enabledTypes);
        }
        
        if (this.tactics.length === 0) {
          this.setStatus('');
          this.loading = false;
          return;
        }
        
        // Shuffle tactics
        this.tactics = this.shuffle(this.tactics);
        
        // Start training
        this.currentIndex = 0;
        this.training = true; // show the board panel
        this.setStatus('');

        // Ensure the board element has real dimensions before init
        await this.$nextTick();
        await this.ensureBoardReady();
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
      
      const since = Date.now() - (90 * 24 * 60 * 60 * 1000); // 3 months
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
      
      // Fetch last 3 months
      for (let i = 0; i < 3 && games.length < this.numGames; i++) {
        const year = now.getFullYear();
        const month = String(now.getMonth() + 1).padStart(2, '0');
        
        try {
          const res = await fetch(`https://api.chess.com/pub/player/${username.toLowerCase()}/games/${year}/${month}/pgn`);
          if (res.ok) {
            const pgn = await res.text();
            const monthGames = this.splitPgn(pgn);
            
            // Filter by time control
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
      
      // Parse headers
      const headers = {};
      for (const match of pgn.matchAll(/\[(\w+)\s+"([^"]*)"\]/g)) {
        headers[match[1]] = match[2];
      }
      
      // Find user's color
      const white = (headers.White || '').toLowerCase();
      const black = (headers.Black || '').toLowerCase();
      let userColor = null;
      if (white.includes(userLower)) userColor = 'w';
      else if (black.includes(userLower)) userColor = 'b';
      else return [];
      
      // Extract moves text
      const movesMatch = pgn.match(/\n\n([\s\S]+)$/);
      if (!movesMatch) return [];
      
      const movesText = movesMatch[1]
        .replace(/\{[^}]*\}/g, '')
        .replace(/\([^)]*\)/g, '')
        .replace(/\$\d+/g, '')
        .replace(/\d+\.\.\./g, '')
        .trim();
      
      // Parse moves
      const moves = [];
      for (const m of movesText.matchAll(/(\d+)\.\s*(\S+)(?:\s+(\S+))?/g)) {
        const num = parseInt(m[1]);
        if (m[2] && !this.isResult(m[2])) moves.push({ num, san: m[2], color: 'w' });
        if (m[3] && !this.isResult(m[3])) moves.push({ num, san: m[3], color: 'b' });
      }
      
      // Replay and analyze
      const tactics = [];
      const game = new Chess.Game();
      
      for (const move of moves) {
        const isUserMove = move.color === userColor;
        
        if (!isUserMove) {
          const uci = this.findUci(game, move.san);
          if (uci) {
            game.moveUci(uci);
          } else {
            console.warn(`Failed to parse opponent move: ${move.san} in game ${gameId}`);
            break; // Stop analyzing this game if we lose track of state
          }
          continue;
        }
        
        // User's move - analyze before and after
        const fenBefore = game.getFen();
        const evalBefore = await this.stockfish.analyze(fenBefore, 15);
        
        const uci = this.findUci(game, move.san);
        if (!uci) {
          console.warn(`Failed to parse user move: ${move.san} in game ${gameId}`);
          break; // Stop analyzing this game
        }
        game.moveUci(uci);
        
        const fenAfter = game.getFen();
        const evalAfter = await this.stockfish.analyze(fenAfter, 15);
        
        // Calculate win chance delta
        let cpBefore = (evalBefore.eval || 0) * 100;
        let cpAfter = (evalAfter.eval || 0) * 100;
        
        // CRITICAL: cpAfter is from opponent's perspective (their turn after user moved)
        // Negate it to get user's perspective, matching how Flutter normalizes in StockfishService
        cpAfter = -cpAfter;
        
        if (userColor === 'b') {
          cpBefore = -cpBefore;
          cpAfter = -cpAfter;
        }
        
        // Skip if position is already hopeless (worse than -4 pawns even with best play)
        if (cpBefore < -400) continue;
        
        // Skip if position is too winning (better than +5) AND still comfortable after the mistake
        // But keep it if the mistake dropped us significantly (e.g., +10 to +1)
        if (cpBefore > 500 && cpAfter > 100) continue;
        
        // Use Lichess [-1, +1] scale for classification
        const wcBefore = winningChances(cpBefore);
        const wcAfter = winningChances(cpAfter);
        const delta = wcBefore - wcAfter;
        
        // Lichess thresholds (from lila/modules/tree/src/main/Advice.scala)
        // Blunder: >= 0.3, Mistake: >= 0.2, Inaccuracy: >= 0.1
        if (delta >= 0.2) {
          const isBlunder = delta >= 0.3;
          
          // Store UCI line directly - convert to SAN only when displaying
          const uciLine = evalBefore.pv?.slice(0, 3) || [];
          
          // Use winPercent for display
          const wpBefore = winPercent(cpBefore);
          const wpAfter = winPercent(cpAfter);
          
          tactics.push({
            fen: fenBefore,
            user_move: move.san,
            correct_line: uciLine,
            mistake_type: isBlunder ? '??' : '?',
            mistake_analysis: `${isBlunder ? 'Blunder' : 'Mistake'}: ${wpBefore.toFixed(0)}% → ${wpAfter.toFixed(0)}%`,
            position_context: `Move ${move.num}, ${userColor === 'w' ? 'White' : 'Black'} to play`,
            game_url: headers.Link || headers.Site || '',
            game_white: headers.White || '',
            game_black: headers.Black || '',
          });
        }
      }
      
      return tactics;
    },
    
    isResult(s) {
      return ['1-0', '0-1', '1/2-1/2', '*'].includes(s);
    },
    
    // Convert a line of UCI moves to SAN for display (used during analysis)
    convertUciLineToSan(fen, uciMoves) {
      if (!fen || !uciMoves?.length) return uciMoves || [];
      
      try {
        const game = new Chess.Game(fen);
        const sanMoves = [];
        
        for (const uci of uciMoves) {
          const san = this.uciToSan(game, uci);
          if (san) {
            sanMoves.push(san);
            game.moveUci(uci);
          } else {
            // Fallback to UCI if conversion fails
            sanMoves.push(uci);
          }
        }
        return sanMoves;
      } catch (e) {
        console.warn('Failed to convert UCI to SAN:', e);
        return uciMoves;
      }
    },
    
    findUci(game, san) {
      // Parse the SAN move properly
      const parsed = this.parseSan(san);
      if (!parsed) return null;
      
      for (let sq = 0; sq < 64; sq++) {
        const piece = game.board[sq];
        if (!piece || piece.color !== game.turn) continue;
        
        const moves = game.getLegalMoves(sq);
        for (const m of moves) {
          if (this.matchesParsedSan(game, m, parsed)) {
            return m.fromAlg + m.toAlg + (m.promotion || '');
          }
        }
      }
      return null;
    },
    
    // Parse SAN into structured components
    parseSan(san) {
      // Handle castling
      if (san === 'O-O' || san === '0-0') {
        return { castling: 'K' };
      }
      if (san === 'O-O-O' || san === '0-0-0') {
        return { castling: 'Q' };
      }
      
      // Strip check/checkmate symbols
      let s = san.replace(/[+#!?]/g, '');
      
      // Extract promotion piece (e.g., e8=Q or e8Q)
      let promotion = null;
      const promoMatch = s.match(/[=]?([QRBN])$/i);
      if (promoMatch) {
        promotion = promoMatch[1].toLowerCase();
        s = s.replace(/[=]?[QRBN]$/i, '');
      }
      
      // Now s should be like: e4, exd5, Nf3, Nbd2, R1e1, Qxe4, etc.
      
      // Extract destination square (always last 2 chars now)
      if (s.length < 2) return null;
      const dest = s.slice(-2);
      if (!/^[a-h][1-8]$/.test(dest)) return null;
      s = s.slice(0, -2);
      
      // Check for capture marker
      const isCapture = s.includes('x');
      s = s.replace('x', '');
      
      // Determine piece type
      let pieceType = 'p'; // default pawn
      if (s.length > 0 && /^[KQRBN]$/.test(s[0])) {
        pieceType = s[0].toLowerCase();
        s = s.slice(1);
      }
      
      // What remains is disambiguation (file, rank, or both)
      let disambigFile = null;
      let disambigRank = null;
      if (s.length === 1) {
        if (/^[a-h]$/.test(s)) {
          disambigFile = s;
        } else if (/^[1-8]$/.test(s)) {
          disambigRank = s;
        }
      } else if (s.length === 2) {
        disambigFile = s[0];
        disambigRank = s[1];
      }
      
      // For pawn captures, the character before 'x' in original SAN is the file
      if (pieceType === 'p' && isCapture) {
        const cleanSan = san.replace(/[+#!?]/g, '').replace(/[=]?[QRBN]$/i, '');
        const xIndex = cleanSan.indexOf('x');
        if (xIndex > 0) {
          disambigFile = cleanSan[xIndex - 1];
        }
      }
      
      return { pieceType, dest, promotion, isCapture, disambigFile, disambigRank };
    },
    
    matchesParsedSan(game, move, parsed) {
      const piece = game.board[move.from];
      if (!piece) return false;
      
      // Handle castling
      if (parsed.castling) {
        if (!move.castling) return false;
        const expected = piece.color === 'w' ? parsed.castling : parsed.castling.toLowerCase();
        return move.castling === expected;
      }
      
      // Check piece type
      if (piece.type !== parsed.pieceType) return false;
      
      // Check destination
      if (move.toAlg !== parsed.dest) return false;
      
      // Check promotion
      if (parsed.promotion) {
        if (move.promotion !== parsed.promotion) return false;
      }
      
      // Check disambiguation
      if (parsed.disambigFile && move.fromAlg[0] !== parsed.disambigFile) return false;
      if (parsed.disambigRank && move.fromAlg[1] !== parsed.disambigRank) return false;
      
      return true;
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
    initBoard() {
      if (!this.board) {
        this.board = new ChessBoard.Board('board', {
          interactive: true,
          onMove: (uci) => this.handleMove(uci)
        });
      }
    },

    async ensureBoardReady() {
      const el = document.getElementById('board');
      if (!el) return;

      await this.waitForVisible(el);
      this.initBoard();
      if (this.board?.redraw) {
        this.board.redraw();
      }
    },
    
    loadCurrentTactic() {
      const t = this.currentTactic;
      if (!t) return;
      
      this.solved = false;
      this.solutionShown = false;
      this.setMessage('Find the best move', '');
      
      const isBlack = t.position_context?.includes('Black');
      this.board.setFlipped(isBlack);
      this.board.setPosition(t.fen);
      this.board.setInteractive(true);
    },
    
    handleMove(uci) {
      if (this.solved) return;
      
      // correct_line stores UCI - compare directly
      const correctUci = this.currentTactic?.correct_line?.[0]?.toLowerCase() || '';
      const playedUci = uci.toLowerCase();
      
      // Simple UCI comparison
      const isCorrect = playedUci === correctUci;
      
      if (isCorrect) {
        this.solved = true;
        this.setMessage('Correct!', 'correct');
        this.board.setInteractive(false);
      } else {
        this.setMessage('Try again', 'incorrect');
        setTimeout(() => {
          this.board.setPosition(this.currentTactic.fen);
          this.setMessage('Find the best move', '');
        }, 800);
      }
    },
    
    showSolution() {
      this.solutionShown = true;
      const uciLine = this.currentTactic?.correct_line || [];
      
      // Convert UCI to SAN for display
      const sanLine = this.convertUciLineToSan(this.currentTactic?.fen, uciLine);
      
      this.setMessage(`Solution: ${sanLine.join(' ') || '?'}`, '');
      // Keep board interactive - user must play the move
    },
    
    uciToSan(game, uci) {
      if (!uci || uci.length < 4) return null;
      
      const from = uci.substring(0, 2);
      const to = uci.substring(2, 4);
      const promo = uci.length > 4 ? uci[4] : null;
      
      // Use the game's algebraicToIndex method for correct board indexing
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
      const isCapture = !!captured || (piece.type === 'p' && from[0] !== to[0]); // en passant
      
      let san = '';
      
      if (piece.type === 'p') {
        // Pawn move
        if (isCapture) {
          san = from[0] + 'x' + to;
        } else {
          san = to;
        }
        if (promo) {
          san += '=' + promo.toUpperCase();
        }
      } else {
        // Piece move
        san = piece.type.toUpperCase();
        
        // Check for ambiguity
        const disambig = this.getDisambiguation(game, piece, fromSq, toSq);
        san += disambig;
        
        if (isCapture) san += 'x';
        san += to;
      }
      
      return san;
    },
    
    getDisambiguation(game, piece, fromSq, toSq) {
      // Find other pieces of same type that can move to same square
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
      
      // Use game's indexToAlgebraic to get correct file/rank
      const fromAlg = game.indexToAlgebraic(fromSq);
      const fromFile = fromAlg[0];
      const fromRank = fromAlg[1];
      
      const sameFile = others.some(sq => game.indexToAlgebraic(sq)[0] === fromFile);
      const sameRank = others.some(sq => game.indexToAlgebraic(sq)[1] === fromRank);
      
      if (!sameFile) return fromFile; // file letter
      if (!sameRank) return fromRank; // rank number
      return fromFile + fromRank; // both
    },
    
    nextTactic() {
      if (this.currentIndex < this.tactics.length - 1) {
        this.currentIndex++;
        this.loadCurrentTactic();
      } else {
        this.setMessage('All done!', 'correct');
      }
    },
    
    backToSetup() {
      this.training = false;
      this.tactics = [];
      this.currentIndex = 0;
    },
    
    setStatus(text, type = '') {
      this.status = text;
      this.statusType = type;
    },
    
    setMessage(text, type = '') {
      this.message = text;
      this.messageClass = type;
    },

    waitForVisible(el, timeout = 3000) {
      return new Promise((resolve) => {
        const start = performance.now();
        const check = () => {
          const style = getComputedStyle(el);
          const visible = el.isConnected &&
            style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            el.offsetWidth > 10 &&
            el.offsetHeight > 10;

          if (visible) {
            resolve();
            return;
          }

          if (performance.now() - start > timeout) {
            resolve(); // best effort fallback
            return;
          }

          requestAnimationFrame(check);
        };
        check();
      });
    }
  };
}
