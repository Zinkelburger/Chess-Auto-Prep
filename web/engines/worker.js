// Web Worker adapter for Stockfish.js
// This follows the standard Emscripten Module pattern for configuration.

var Module = {
  locateFile: function(path, prefix) {
    if (path.indexOf('stockfish.wasm') > -1) {
      return prefix + 'stockfish.wasm';
    }
    return prefix + path;
  },
  onRuntimeInitialized: function() {
    postMessage('worker_ready');
  },
  print: function(text) {
    postMessage(text);
  },
  printErr: function(text) {
    console.warn('[SF Worker]', text);
  }
};

try {
  importScripts('stockfish.js');
} catch (e) {
  console.error('[SF Worker] Load failed:', e);
  postMessage('error: ' + e.message);
}
