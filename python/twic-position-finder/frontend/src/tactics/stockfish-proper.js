/**
 * Proper Stockfish.js wrapper using Chess.com's official package
 * This should have correct NNUE evaluations
 */

export class ProperStockfishEngine {
  constructor() {
    this.worker = null;
    this.ready = false;
    this.analyzing = false;
    this.resolve = null;
    this.currentEval = null;
    this.bestMove = null;
    this.pv = [];
    this.initPromise = null;
    this.engineName = 'Stockfish 17.1';
  }

  async init() {
    if (this.ready) return;
    if (this.initPromise) return this.initPromise;

    this.initPromise = new Promise((resolve, reject) => {
      try {
        // Use the multi-threaded version with NNUE
        const workerPath = '/stockfish/stockfish-17.1-8e4d048.js';
        console.log('Loading Stockfish.js from:', workerPath);

        this.worker = new Worker(workerPath);

        this.worker.onerror = (e) => {
          console.error('Stockfish worker error:', e);
          reject(new Error('Failed to load Stockfish engine'));
        };

        this.worker.onmessage = (e) => {
          const msg = e.data;
          console.log('Stockfish:', msg);

          // Check for NNUE loading
          if (msg.includes('info string NNUE evaluation')) {
            console.log('✅ NNUE evaluation confirmed active!');
          }

          if (msg.includes('uciok')) {
            console.log('UCI ready, configuring engine...');

            // Configure for strong multithreaded play
            const cores = navigator.hardwareConcurrency || 4;
            // Use most cores but leave some for the browser
            const threads = Math.max(1, Math.min(cores - 1, 8));

            console.log(`System has ${cores} cores, using ${threads} threads for Stockfish`);

            this.worker.postMessage('setoption name Hash value 256');  // More hash for better analysis
            this.worker.postMessage(`setoption name Threads value ${threads}`);
            this.worker.postMessage('setoption name MultiPV value 1');

            // Enable CORS-required features for multithreading
            console.log('Note: Multithreading requires proper CORS headers (Cross-Origin-Embedder-Policy and Cross-Origin-Opener-Policy)');

            // Verify NNUE is active
            this.worker.postMessage('d');

            this.worker.postMessage('isready');
          }

          if (msg.includes('readyok') && !this.analyzing) {
            this.ready = true;
            console.log('✅ Stockfish.js ready for analysis');
            resolve();
          }

          // Parse evaluation during analysis
          if (msg.startsWith('info') && msg.includes(' pv ')) {
            const depthMatch = msg.match(/depth (\d+)/);
            const cpMatch = msg.match(/score cp (-?\d+)/);
            const mateMatch = msg.match(/score mate (-?\d+)/);
            const pvMatch = msg.match(/ pv (.+)/);

            if (cpMatch) {
              const rawCp = parseFloat(cpMatch[1]);
              this.currentEval = rawCp / 100;
              console.log(`Depth ${depthMatch ? depthMatch[1] : '?'}: ${this.currentEval} pawns`);
            } else if (mateMatch) {
              const mateIn = parseInt(mateMatch[1]);
              this.currentEval = mateIn > 0 ? 100 : -100;
              console.log(`Depth ${depthMatch ? depthMatch[1] : '?'}: Mate in ${mateIn}`);
            }

            if (pvMatch) {
              this.pv = pvMatch[1].split(' ');
            }
          }

          if (msg.startsWith('bestmove')) {
            const match = msg.match(/bestmove (\S+)/);
            if (match) {
              this.bestMove = match[1];
            }

            this.analyzing = false;
            console.log(`Analysis complete: ${this.currentEval} pawns, best: ${this.bestMove}`);

            if (this.resolve) {
              this.resolve({
                eval: this.currentEval || 0,
                bestMove: this.bestMove,
                pv: [...this.pv],
                engine: this.engineName
              });
              this.resolve = null;
            }
          }
        };

        // Start UCI
        console.log('Sending UCI command...');
        this.worker.postMessage('uci');

        // Timeout protection
        setTimeout(() => {
          if (!this.ready) {
            reject(new Error('Stockfish initialization timeout'));
          }
        }, 15000);

      } catch (error) {
        console.error('Failed to initialize Stockfish:', error);
        reject(error);
      }
    });

    return this.initPromise;
  }

  async analyze(fen, depth = 15) {
    if (!this.ready) {
      await this.init();
    }

    console.log(`Analyzing position: ${fen} at depth ${depth}`);

    return new Promise((resolve, reject) => {
      this.resolve = resolve;
      this.analyzing = true;
      this.currentEval = null;
      this.bestMove = null;
      this.pv = [];

      // New game for clean analysis
      this.worker.postMessage('ucinewgame');

      // Wait a bit for engine to reset
      setTimeout(() => {
        // Set position
        this.worker.postMessage(`position fen ${fen}`);

        // Debug to verify position
        this.worker.postMessage('d');

        // Start analysis
        setTimeout(() => {
          this.worker.postMessage(`go depth ${depth}`);
        }, 50);
      }, 100);

      // Timeout protection
      setTimeout(() => {
        if (this.analyzing) {
          console.error('Analysis timeout');
          this.analyzing = false;
          reject(new Error('Analysis timeout'));
        }
      }, 30000);
    });
  }

  stop() {
    if (this.analyzing && this.worker) {
      this.worker.postMessage('stop');
    }
  }

  destroy() {
    if (this.worker) {
      this.worker.postMessage('quit');
      this.worker.terminate();
      this.worker = null;
      this.ready = false;
    }
  }
}