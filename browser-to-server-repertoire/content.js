// Lichess Repertoire Sync - Content Script
// Injects "Add to Repertoire" button into analysis board context menu

(function() {
  'use strict';

  const REPERTOIRE_SERVER = 'http://localhost:9812/add-line';

  // Glyph symbol mapping (from Lichess glyphs)
  const GLYPH_SYMBOLS = {
    1: '!',   // Good move
    2: '?',   // Mistake
    3: '!!',  // Brilliant move
    4: '??',  // Blunder
    5: '!?',  // Interesting move
    6: '?!',  // Dubious move
    7: '□',   // Only move
    10: '=',  // Equal position
    13: '∞',  // Unclear position
    14: '⩲',  // White is slightly better
    15: '⩱',  // Black is slightly better
    16: '±',  // White is better
    17: '∓',  // Black is better
    18: '+-', // White is winning
    19: '-+', // Black is winning
  };

  // Convert ply to move number notation
  function plyPrefix(node) {
    const moveNum = Math.floor((node.ply + 1) / 2);
    return node.ply % 2 === 1 ? `${moveNum}.` : `${moveNum}...`;
  }

  // Build PGN with comments and annotations
  function buildDetailedPgn(nodeList, game) {
    const filteredNodes = nodeList.filter(n => n.san);
    if (filteredNodes.length === 0) return '';

    let pgn = '';

    // Add PGN headers for variant/FEN if needed
    if (game.variant?.key !== 'standard') {
      pgn += `[Variant "${game.variant.name}"]\n`;
    }
    if (game.initialFen && game.initialFen !== 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1') {
      pgn += `[FEN "${game.initialFen}"]\n`;
    }
    if (pgn) pgn += '\n';

    // Build move list with annotations
    for (let i = 0; i < filteredNodes.length; i++) {
      const node = filteredNodes[i];

      // Add move number for white's moves or if first move
      if (node.ply % 2 === 1 || i === 0) {
        pgn += plyPrefix(node) + ' ';
      }

      // Add the move
      pgn += node.san;

      // Add glyphs (annotations like !, ?, !!)
      if (node.glyphs && node.glyphs.length > 0) {
        for (const glyph of node.glyphs) {
          const symbol = GLYPH_SYMBOLS[glyph.id] || '';
          if (symbol) pgn += symbol;
        }
      }

      // Add comments
      if (node.comments && node.comments.length > 0) {
        const commentText = node.comments
          .map(c => c.text)
          .join(' ')
          .trim();
        if (commentText) {
          pgn += ` { ${commentText} }`;
        }
      }

      pgn += ' ';
    }

    return pgn.trim();
  }

  // Extract structured line data
  function extractLineData(nodeList, game) {
    return {
      pgn: buildDetailedPgn(nodeList, game),
      moves: nodeList.filter(n => n.san).map(node => ({
        ply: node.ply,
        moveNumber: Math.floor((node.ply + 1) / 2),
        color: node.ply % 2 === 1 ? 'white' : 'black',
        san: node.san,
        uci: node.uci,
        fen: node.fen,
        comments: node.comments?.map(c => c.text) || [],
        glyphs: node.glyphs?.map(g => ({
          id: g.id,
          symbol: GLYPH_SYMBOLS[g.id] || '',
          name: g.name
        })) || [],
        eval: node.eval ? {
          cp: node.eval.cp,
          mate: node.eval.mate,
          best: node.eval.best
        } : null
      })),
      startFen: game.initialFen || 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      variant: game.variant?.key || 'standard'
    };
  }

  // Send line to repertoire server
  async function sendToRepertoire(lineData) {
    try {
      const response = await fetch(REPERTOIRE_SERVER, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(lineData)
      });

      if (!response.ok) {
        throw new Error(`Server responded with ${response.status}`);
      }

      const data = await response.json();
      return { success: true, data };
    } catch (error) {
      console.error('Failed to send to repertoire:', error);
      return { success: false, error: error.message };
    }
  }

  // Show notification to user
  function showNotification(message, isError = false) {
    // Use Lichess's notification system if available
    if (window.lichess?.notifyApp) {
      window.lichess.notifyApp(message);
    } else {
      // Fallback: create a simple toast notification
      const toast = document.createElement('div');
      toast.textContent = message;
      toast.style.cssText = `
        position: fixed;
        top: 60px;
        right: 20px;
        background: ${isError ? '#d32f2f' : '#2e7d32'};
        color: white;
        padding: 12px 24px;
        border-radius: 4px;
        z-index: 10000;
        font-size: 14px;
        box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      `;
      document.body.appendChild(toast);
      setTimeout(() => toast.remove(), 3000);
    }
  }

  // Try multiple methods to get the analyse controller
  function getAnalyseController() {
    console.log('[REPERTOIRE] Attempting to find analyse controller...');
    console.log('[REPERTOIRE] window.lichess:', window.lichess);

    if (window.lichess) {
      console.log('[REPERTOIRE] window.lichess keys:', Object.keys(window.lichess));
    }

    // Method 1: Direct access via window.lichess.analyse
    if (window.lichess?.analyse) {
      console.log('[REPERTOIRE] Found controller via window.lichess.analyse');
      return window.lichess.analyse;
    }

    // Method 2: Check for LichessAnalyse global
    if (window.LichessAnalyse) {
      console.log('[REPERTOIRE] Found controller via window.LichessAnalyse');
      return window.LichessAnalyse;
    }

    // Method 3: Access via site.analysis (different builds might use this)
    if (window.site?.analysis) {
      console.log('[REPERTOIRE] Found controller via window.site.analysis');
      return window.site.analysis;
    }

    // Method 4: Look for it in the global scope
    if (typeof analysis !== 'undefined') {
      console.log('[REPERTOIRE] Found controller in global scope as analysis');
      return window.analysis;
    }

    // Method 5: Try to find it on the main element
    const mainElement = document.querySelector('main.analyse');
    if (mainElement) {
      console.log('[REPERTOIRE] Found main.analyse element, checking for stored data');
      // Snabbdom/Mithril might store data on DOM elements
      for (let key in mainElement) {
        if (key.startsWith('__') || key.includes('data') || key.includes('ctrl')) {
          console.log(`[REPERTOIRE] mainElement['${key}']:`, mainElement[key]);
        }
      }
    }

    console.warn('[REPERTOIRE] Could not find analyse controller anywhere');
    console.log('[REPERTOIRE] All window properties containing "lichess":',
      Object.keys(window).filter(k => k.toLowerCase().includes('lichess')));
    console.log('[REPERTOIRE] All window properties containing "analyse":',
      Object.keys(window).filter(k => k.toLowerCase().includes('analyse')));

    return null;
  }

  // Inject our button into the context menu
  function injectRepertoireButton(menu, path) {
    console.log('[REPERTOIRE] injectRepertoireButton called with menu:', menu, 'path:', path);

    // Check if button already exists
    if (menu.querySelector('.repertoire-action')) {
      console.log('[REPERTOIRE] Repertoire button already exists, skipping injection');
      return;
    }

    console.log('[REPERTOIRE] Creating button...');

    // Create our button
    const button = document.createElement('a');
    button.className = 'action repertoire-action';
    button.innerHTML = '<i data-icon=""></i>Add to repertoire';
    button.style.cssText = 'cursor: pointer;';
    console.log('[REPERTOIRE] Created button element:', button);

    button.onclick = async (e) => {
      console.log('[REPERTOIRE] Button clicked!');
      e.preventDefault();
      e.stopPropagation();

      // Extract line data directly from DOM instead of using the controller
      try {
        // Find all moves up to and including the clicked path
        const allMoves = document.querySelectorAll('move[p]');
        console.log('[REPERTOIRE] Found', allMoves.length, 'moves in DOM');

        // Find the clicked move and get all moves up to it
        const movesUpToPath = [];
        let foundTargetMove = false;

        for (const moveEl of allMoves) {
          const movePath = moveEl.getAttribute('p');
          const san = moveEl.querySelector('san')?.textContent;

          if (san) {
            movesUpToPath.push({ path: movePath, san: san });
          }

          // Check if this move or any parent is our target
          if (path.startsWith(movePath) || movePath === path) {
            if (movePath === path) {
              foundTargetMove = true;
              break;
            }
          }
        }

        if (!foundTargetMove) {
          // Just collect all moves with matching prefix
          movesUpToPath.length = 0;
          for (const moveEl of allMoves) {
            const movePath = moveEl.getAttribute('p');
            const san = moveEl.querySelector('san')?.textContent;

            if (path.startsWith(movePath) && san) {
              movesUpToPath.push({ path: movePath, san: san });
            }
          }
        }

        console.log('[REPERTOIRE] Moves up to path:', movesUpToPath);

        // Build PGN from moves
        let pgn = '';
        movesUpToPath.forEach((move, i) => {
          const moveNum = Math.floor(i / 2) + 1;
          if (i % 2 === 0) {
            pgn += `${moveNum}. ${move.san} `;
          } else {
            pgn += `${move.san} `;
          }
        });

        console.log('[REPERTOIRE] Built PGN:', pgn);

        // Create simple line data (without evals/comments for now)
        const lineData = {
          pgn: pgn.trim(),
          moves: movesUpToPath.map((move, i) => ({
            ply: i + 1,
            moveNumber: Math.floor(i / 2) + 1,
            color: i % 2 === 0 ? 'white' : 'black',
            san: move.san,
            path: move.path
          })),
          startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          variant: 'standard'
        };

        console.log('[REPERTOIRE] Sending to repertoire:', lineData);

        // Send to server
        const result = await sendToRepertoire(lineData);
        console.log('[REPERTOIRE] Server response:', result);

        if (result.success) {
          if (result.data?.status === 'duplicate') {
            showNotification('Line already in repertoire');
          } else {
            showNotification('Line added to repertoire!');
          }
        } else {
          showNotification(`Failed to add line: ${result.error}`, true);
        }
      } catch (error) {
        console.error('[REPERTOIRE] Error:', error);
        showNotification(`Error: ${error.message}`, true);
      }

      // Close the context menu
      menu.remove();
    };

    // Insert before the delete action or at the end
    const allActions = menu.querySelectorAll('.action');
    console.log('[REPERTOIRE] Found existing actions in menu:', allActions.length);

    const deleteAction = Array.from(allActions)
      .find(a => a.textContent.includes('Delete'));

    console.log('[REPERTOIRE] Delete action found:', deleteAction);

    if (deleteAction) {
      console.log('[REPERTOIRE] Inserting button before delete action');
      menu.insertBefore(button, deleteAction);
    } else {
      console.log('[REPERTOIRE] No delete action, appending button to end');
      menu.appendChild(button);
    }

    console.log('[REPERTOIRE] Button successfully injected into menu!');
  }

  // Store the last clicked move's path
  let lastClickedPath = null;

  // Listen for right-clicks on moves to capture the path
  function setupMoveClickListener() {
    console.log('[REPERTOIRE] Setting up move click listener');

    document.addEventListener('contextmenu', (e) => {
      // Find the move element that was clicked
      const moveElement = e.target.closest('move');
      if (moveElement) {
        const path = moveElement.getAttribute('p');
        console.log('[REPERTOIRE] Right-clicked on move, path:', path);
        console.log('[REPERTOIRE] Move element:', moveElement);
        lastClickedPath = path;
      }
    }, true); // Use capture phase to catch it early

    console.log('[REPERTOIRE] Move click listener active');
  }

  // Monitor for context menu creation and updates
  function setupContextMenuObserver() {
    console.log('[REPERTOIRE] Setting up context menu observer');

    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        // Watch for new nodes being added (initial menu creation)
        for (const node of mutation.addedNodes) {
          if (node.nodeType === 1) { // Element node
            // Check for the actual Lichess context menu by ID
            const menu = node.id === 'analyse-cm'
              ? node
              : node.querySelector?.('#analyse-cm');

            if (menu) {
              console.log('[REPERTOIRE] Found menu in addedNodes, visible?', menu.classList.contains('visible'));
              console.log('[REPERTOIRE] Menu element:', menu);

              if (menu.classList.contains('visible')) {
                console.log('[REPERTOIRE] Using lastClickedPath:', lastClickedPath);

                if (lastClickedPath) {
                  // Use setTimeout to ensure Snabbdom is done patching
                  console.log('[REPERTOIRE] Injecting button with path:', lastClickedPath);
                  setTimeout(() => injectRepertoireButton(menu, lastClickedPath), 0);
                } else {
                  console.warn('[REPERTOIRE] No path found in lastClickedPath');
                }
              }
            }
          }
        }

        // Watch for the menu becoming visible (class changes)
        if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
          const target = mutation.target;
          if (target.id === 'analyse-cm') {
            console.log('[REPERTOIRE] Menu class changed, visible?', target.classList.contains('visible'));

            if (target.classList.contains('visible')) {
              console.log('[REPERTOIRE] Menu became visible via class change');
              console.log('[REPERTOIRE] Using lastClickedPath:', lastClickedPath);

              if (lastClickedPath) {
                // Use setTimeout to ensure Snabbdom is done patching
                console.log('[REPERTOIRE] Injecting button with path:', lastClickedPath);
                setTimeout(() => injectRepertoireButton(target, lastClickedPath), 0);
              } else {
                console.warn('[REPERTOIRE] No path found in lastClickedPath');
              }
            }
          }
        }

        // Watch for menu content changes (Snabbdom patches)
        if (mutation.type === 'childList' && mutation.target.id === 'analyse-cm') {
          const menu = mutation.target;
          console.log('[REPERTOIRE] Menu content changed, visible?', menu.classList.contains('visible'));

          if (menu.classList.contains('visible')) {
            console.log('[REPERTOIRE] Using lastClickedPath:', lastClickedPath);

            if (lastClickedPath) {
              // Use setTimeout to ensure Snabbdom is done patching
              console.log('[REPERTOIRE] Injecting button with path:', lastClickedPath);
              setTimeout(() => injectRepertoireButton(menu, lastClickedPath), 0);
            } else {
              console.warn('[REPERTOIRE] No path found in lastClickedPath');
            }
          }
        }
      }
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class']
    });

    console.log('[REPERTOIRE] Context menu observer active and watching');
  }

  // Wait for page to be fully loaded and Lichess to be ready
  function init() {
    console.log('[REPERTOIRE] Initializing extension');
    console.log('[REPERTOIRE] window.lichess:', window.lichess);

    // Log all properties of window.lichess to see what's available
    if (window.lichess) {
      console.log('[REPERTOIRE] window.lichess properties:', Object.keys(window.lichess));
    }

    // Check if we're on an analysis page by looking for the analyse-cm menu
    const existingMenu = document.getElementById('analyse-cm');
    console.log('[REPERTOIRE] Existing analyse-cm menu:', existingMenu);

    // Don't wait for lichess.analyse - just start observing immediately
    // We'll get the path directly from clicked move elements
    console.log('[REPERTOIRE] Setting up observers immediately');
    setupMoveClickListener();
    setupContextMenuObserver();
  }

  // Start when DOM is ready
  console.log('[REPERTOIRE] Content script loaded, document.readyState:', document.readyState);
  if (document.readyState === 'loading') {
    console.log('[REPERTOIRE] Waiting for DOMContentLoaded');
    document.addEventListener('DOMContentLoaded', init);
  } else {
    console.log('[REPERTOIRE] DOM already loaded, initializing now');
    init();
  }

})();
