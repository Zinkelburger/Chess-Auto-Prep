/**
 * Stockfish.js wrapper with multi-threaded → single-threaded fallback.
 *
 * Multi-threaded (stockfish-mt.js) requires SharedArrayBuffer, which
 * needs Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy
 * headers. If those aren't present or the browser doesn't support it,
 * falls back to the single-threaded build (stockfish.js).
 */

export class ProperStockfishEngine {
  constructor() {
    this.worker = null;
    this.ready = false;
    this.analyzing = false;
    this.resolve = null;
    this.reject = null;
    this.analysisTimeout = null;
    this.currentEval = null;
    this.bestMove = null;
    this.pv = [];
    this.initPromise = null;
    this.engineName = 'Stockfish';
  }

  async init(threads = 1) {
    if (this.ready) return;
    if (this.initPromise) return this.initPromise;

    threads = Math.max(1, threads);
    const wantMultiThreaded = threads > 1 && crossOriginIsolated;

    this.initPromise = (async () => {
      if (wantMultiThreaded) {
        try {
          await this._startWorker('/stockfish/stockfish-mt.js');
          console.log(`Multi-threaded mode: ${threads} threads`);
          this.worker.postMessage(`setoption name Threads value ${threads}`);
          this.worker.postMessage('setoption name Hash value 256');
          this.worker.postMessage('setoption name MultiPV value 1');
          this.worker.postMessage('isready');
          await this._waitReady();
          return;
        } catch (e) {
          console.warn('Multi-threaded engine failed, falling back to single-threaded:', e.message);
          this._cleanup();
        }
      } else if (threads > 1) {
        console.log('crossOriginIsolated is false — falling back to single-threaded engine');
      }

      await this._startWorker('/stockfish/stockfish.js');
      console.log('Single-threaded mode');
      this.worker.postMessage('setoption name Hash value 128');
      this.worker.postMessage('setoption name MultiPV value 1');
      this.worker.postMessage('isready');
      await this._waitReady();
    })();

    return this.initPromise;
  }

  _startWorker(path) {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Worker load timeout')), 10000);

      console.log('Loading Stockfish.js from:', path);
      this.worker = new Worker(path);

      this.worker.onerror = (e) => {
        clearTimeout(timeout);
        console.error('Stockfish worker error:', e);
        reject(new Error('Failed to load Stockfish engine'));
      };

      this.worker.onmessage = (e) => {
        const msg = e.data;
        if (msg.includes('uciok')) {
          clearTimeout(timeout);
          console.log('UCI protocol ready');
          resolve();
        }
      };

      this.worker.postMessage('uci');
    });
  }

  _waitReady() {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Engine readyok timeout')), 10000);

      const prev = this.worker.onmessage;
      this.worker.onmessage = (e) => {
        const msg = e.data;
        if (msg.includes('readyok')) {
          clearTimeout(timeout);
          this.ready = true;
          this.worker.onmessage = this._analysisHandler.bind(this);
          console.log('Stockfish.js ready for analysis');
          resolve();
          return;
        }
        if (prev) prev(e);
      };
    });
  }

  _analysisHandler(e) {
    const msg = e.data;

    if (msg.startsWith('info') && msg.includes(' pv ')) {
      const cpMatch = msg.match(/score cp (-?\d+)/);
      const mateMatch = msg.match(/score mate (-?\d+)/);
      const pvMatch = msg.match(/ pv (.+)/);

      if (cpMatch) {
        this.currentEval = parseFloat(cpMatch[1]) / 100;
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
      if (match) this.bestMove = match[1];

      this._settleAnalysis({
        eval: this.currentEval || 0,
        bestMove: this.bestMove,
        pv: [...this.pv],
        engine: this.engineName
      });
    }
  }

  _settleAnalysis(result) {
    if (this.analysisTimeout) {
      clearTimeout(this.analysisTimeout);
      this.analysisTimeout = null;
    }
    this.analyzing = false;

    if (result instanceof Error) {
      console.error('Analysis failed:', result.message);
      if (this.reject) {
        this.reject(result);
      }
    } else {
      console.log(`Analysis complete: ${result.eval} pawns, best: ${result.bestMove}`);
      if (this.resolve) {
        this.resolve(result);
      }
    }
    this.resolve = null;
    this.reject = null;
  }

  _cleanup() {
    if (this.worker) {
      try { this.worker.terminate(); } catch (_) {}
      this.worker = null;
    }
    this.ready = false;
  }

  newGame() {
    if (!this.ready) return;
    this.worker.postMessage('ucinewgame');
    this.worker.postMessage('isready');
    return this._waitSync();
  }

  _waitSync() {
    return new Promise((resolve) => {
      const prev = this.worker.onmessage;
      this.worker.onmessage = (e) => {
        if (e.data.includes('readyok')) {
          this.worker.onmessage = prev;
          resolve();
          return;
        }
        if (prev) prev(e);
      };
    });
  }

  async analyze(fen, depth = 15) {
    if (!this.ready) {
      await this.init();
    }

    if (this.analyzing) {
      this.worker.postMessage('stop');
      this._settleAnalysis(new Error('Aborted by new analyze() call'));
    }

    return new Promise((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
      this.analyzing = true;
      this.currentEval = null;
      this.bestMove = null;
      this.pv = [];

      this.worker.postMessage(`position fen ${fen}`);
      this.worker.postMessage(`go depth ${depth}`);

      this.analysisTimeout = setTimeout(() => {
        this.worker.postMessage('stop');
        this._settleAnalysis(new Error('Analysis timeout'));
      }, 30000);
    });
  }

  stop() {
    if (this.analyzing && this.worker) {
      this.worker.postMessage('stop');
    }
  }

  destroy() {
    if (this.analysisTimeout) {
      clearTimeout(this.analysisTimeout);
      this.analysisTimeout = null;
    }
    if (this.worker) {
      this.worker.postMessage('quit');
      this.worker.terminate();
      this.worker = null;
      this.ready = false;
    }
  }
}
