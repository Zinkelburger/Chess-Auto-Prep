/**
 * Modern Stockfish WASM Engine using @lichess-org/stockfish-web
 * Based on Lichess implementation with SharedArrayBuffer and NNUE support
 */

export class ModernStockfishEngine {
  constructor() {
    this.module = null;
    this.ready = false;
    this.analyzing = false;
    this.resolve = null;
    this.currentEval = null;
    this.bestMove = null;
    this.pv = [];
    this.initPromise = null;
    this.engineName = null;
  }

  async init() {
    if (this.ready) return;
    if (this.initPromise) return this.initPromise;

    this.initPromise = new Promise(async (resolve, reject) => {
      try {
        // Create shared WASM memory for multi-threading
        const wasmMemory = this.createSharedWasmMemory(1536, 32767);

        console.log('Initializing modern Stockfish with SharedArrayBuffer support...');

        // Import the Stockfish 17.1 module directly (7MB version)
        const scriptUrl = '/stockfish-web/sf171-7.js';
        console.log('Importing module from:', scriptUrl);
        const makeModule = await import(/* @vite-ignore */ scriptUrl);
        console.log('Module imported successfully');

        // Initialize the module with SharedArrayBuffer
        console.log('Initializing WASM module...');
        this.module = await makeModule.default({
          wasmMemory,
          locateFile: (file) => {
            console.log('Locating file:', file);
            if (file.endsWith('.wasm')) {
              const wasmPath = `/stockfish-web/${file}`;
              console.log('WASM file path:', wasmPath);
              return wasmPath;
            }
            return file;
          },
          mainScriptUrlOrBlob: scriptUrl
        });
        console.log('WASM module initialized');

        // Set up message handling
        this.module.listen = (data) => {
          console.log('Engine message:', data);
          this.handleEngineMessage(data);
        };

        // Send initial UCI command
        console.log('Sending UCI command...');
        this.module.uci('uci');

        setTimeout(() => {
          if (!this.ready) {
            reject(new Error('Modern Stockfish initialization timeout'));
          }
        }, 15000);

      } catch (error) {
        console.error('Modern Stockfish initialization failed:', error);
        reject(error);
      }
    });

    return this.initPromise;
  }

  createSharedWasmMemory(lo, hi = 32767) {
    let shrink = 4;
    while (true) {
      try {
        console.log(`Attempting to create SharedArrayBuffer memory: ${lo}-${hi} pages`);
        return new WebAssembly.Memory({
          shared: true,
          initial: lo,
          maximum: hi
        });
      } catch (e) {
        if (hi <= lo || !(e instanceof RangeError)) {
          console.warn('SharedArrayBuffer not available, falling back to regular memory');
          // Fallback to regular memory if SharedArrayBuffer fails
          return new WebAssembly.Memory({
            initial: Math.min(lo, 1024),
            maximum: Math.min(hi, 2048)
          });
        }
        hi = Math.max(lo, Math.ceil(hi - hi / shrink));
        shrink = shrink === 4 ? 3 : 4;
      }
    }
  }

  handleEngineMessage(data) {
    const msg = data.trim();

    if (msg.includes('id name')) {
      this.engineName = msg.split('id name ')[1];
      console.log(`Engine name: ${this.engineName}`);
    }

    if (msg.includes('uciok')) {
      console.log('Engine ready, configuring options...');

      // Configure hash table
      this.module.uci('setoption name Hash value 64');

      // Configure threads based on system capabilities
      const threads = this.getOptimalThreadCount();
      console.log(`Setting threads to: ${threads}`);
      this.module.uci(`setoption name Threads value ${threads}`);

      // Enable multi-PV for better analysis
      this.module.uci('setoption name MultiPV value 1');

      this.module.uci('isready');
    }

    if (msg.includes('readyok') && !this.analyzing) {
      this.ready = true;
      console.log('Modern Stockfish ready for analysis');
      this.resolve?.();
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
          pv: [...this.pv],
          engine: this.engineName
        });
        this.resolve = null;
      }
    }
  }

  getOptimalThreadCount() {
    const cores = navigator.hardwareConcurrency || 1;
    const isMobile = /Android|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
    const hasSharedArrayBuffer = typeof SharedArrayBuffer !== 'undefined';

    if (!hasSharedArrayBuffer) {
      return 1; // Single thread fallback
    }

    if (isMobile) {
      return Math.min(cores, 2); // Conservative on mobile
    } else {
      return Math.min(cores, 8); // More aggressive on desktop
    }
  }

  async analyze(fen, depth = 18) {
    if (!this.ready) {
      await this.init();
    }

    return new Promise((resolve) => {
      this.resolve = resolve;
      this.analyzing = true;
      this.currentEval = 0;
      this.bestMove = null;
      this.pv = [];

      this.module.uci('ucinewgame');
      this.module.uci(`position fen ${fen}`);
      this.module.uci(`go depth ${depth}`);
    });
  }

  stop() {
    if (this.analyzing && this.module) {
      this.module.uci('stop');
    }
  }

  destroy() {
    if (this.module) {
      this.module.uci('quit');
      this.module = null;
      this.ready = false;
    }
  }

  // Check if modern features are supported
  static isSupported() {
    const hasWebAssembly = typeof WebAssembly !== 'undefined';
    const hasSharedArrayBuffer = typeof SharedArrayBuffer !== 'undefined';
    const hasSIMD = WebAssembly && typeof WebAssembly.SIMD !== 'undefined';

    return {
      webassembly: hasWebAssembly,
      sharedArrayBuffer: hasSharedArrayBuffer,
      simd: hasSIMD,
      recommended: hasWebAssembly && hasSharedArrayBuffer
    };
  }
}