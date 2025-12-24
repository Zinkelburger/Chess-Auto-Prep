/**
 * Stockfish WASM Wrapper (module version)
 * Runs chess engine analysis in the browser
 */

export class StockfishEngine {
  constructor() {
    this.worker = null;
    this.ready = false;
    this.analyzing = false;
    this.resolve = null;
    this.currentEval = null;
    this.bestMove = null;
    this.pv = [];
    this.initPromise = null;
  }

  async init() {
    if (this.ready) return;
    if (this.initPromise) return this.initPromise;
    
    const workerUrl = '/engines/stockfish.js'; // served from Vite public
    
    this.initPromise = new Promise((resolve, reject) => {
      try {
        this.worker = new Worker(workerUrl);
        
        this.worker.onerror = (e) => {
          console.error('Stockfish worker error:', e);
          reject(new Error('Failed to load Stockfish engine'));
        };

        this.worker.onmessage = (e) => {
          const msg = e.data;
          
          if (msg.includes('uciok')) {
            this.ready = true;
            this.worker.postMessage('setoption name Hash value 32');
            this.worker.postMessage('setoption name Threads value 1');
            this.worker.postMessage('isready');
          }
          
          if (msg.includes('readyok') && !this.analyzing) {
            resolve();
          }
          
          if (msg.startsWith('info depth') && msg.includes(' pv ')) {
            const cpMatch = msg.match(/score cp (-?\d+)/);
            const mateMatch = msg.match(/score mate (-?\d+)/);
            const pvMatch = msg.match(/ pv (.+)/);
            
            if (cpMatch) {
              this.currentEval = parseInt(cpMatch[1]) / 100;
            } else if (mateMatch) {
              const mateIn = parseInt(mateMatch[1]);
              this.currentEval = mateIn > 0 ? 100 : -100;
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
            if (this.resolve) {
              this.resolve({
                eval: this.currentEval,
                bestMove: this.bestMove,
                pv: [...this.pv]
              });
              this.resolve = null;
            }
          }
        };

        this.worker.postMessage('uci');
        
        setTimeout(() => {
          if (!this.ready) {
            reject(new Error('Stockfish initialization timeout'));
          }
        }, 10000);
        
      } catch (e) {
        reject(e);
      }
    });
    
    return this.initPromise;
  }

  async analyze(fen, depth = 14) {
    if (!this.ready) {
      await this.init();
    }
    
    return new Promise((resolve) => {
      this.resolve = resolve;
      this.analyzing = true;
      this.currentEval = 0;
      this.bestMove = null;
      this.pv = [];
      
      this.worker.postMessage('ucinewgame');
      this.worker.postMessage(`position fen ${fen}`);
      this.worker.postMessage(`go depth ${depth}`);
    });
  }

  stop() {
    if (this.analyzing && this.worker) {
      this.worker.postMessage('stop');
    }
  }

  destroy() {
    if (this.worker) {
      this.worker.terminate();
      this.worker = null;
      this.ready = false;
    }
  }
}

