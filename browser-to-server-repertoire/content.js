// Lichess Repertoire Sync - Content Script
// Injects "Add to Repertoire" button into analysis board context menu

(function() {
  'use strict';

  const REPERTOIRE_SERVER = 'http://localhost:9812/add-line';
  const LIST_REPERTOIRES_URL = 'http://localhost:9812/list-repertoires';

  // Cached repertoire list
  let cachedRepertoires = null;
  let cacheTimestamp = null;
  const CACHE_DURATION = 5000; // 5 seconds

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

  // Fetch list of available repertoires
  async function fetchRepertoires() {
    const now = Date.now();

    // Use cache if fresh
    if (cachedRepertoires && cacheTimestamp && (now - cacheTimestamp) < CACHE_DURATION) {
      return cachedRepertoires;
    }

    try {
      const response = await fetch(LIST_REPERTOIRES_URL);
      if (!response.ok) {
        throw new Error(`Server responded with ${response.status}`);
      }
      const data = await response.json();
      cachedRepertoires = data.repertoires || [];
      cacheTimestamp = now;
      return cachedRepertoires;
    } catch (error) {
      console.error('Failed to fetch repertoires:', error);
      return [];
    }
  }

  // Simple fuzzy search implementation
  function fuzzyMatch(text, query) {
    text = text.toLowerCase();
    query = query.toLowerCase();

    let queryIndex = 0;
    let textIndex = 0;

    while (queryIndex < query.length && textIndex < text.length) {
      if (text[textIndex] === query[queryIndex]) {
        queryIndex++;
      }
      textIndex++;
    }

    return queryIndex === query.length;
  }

  // Filter repertoires by search query
  function filterRepertoires(repertoires, query) {
    if (!query) return repertoires;
    return repertoires.filter(r => fuzzyMatch(r.name, query));
  }

  // Send line to repertoire server
  async function sendToRepertoire(lineData, targetRepertoire) {
    try {
      const payload = { ...lineData };
      if (targetRepertoire) {
        payload.targetRepertoire = targetRepertoire;
      }

      const response = await fetch(REPERTOIRE_SERVER, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload)
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

  // Extract line data from DOM
  function extractLineDataFromDOM(path) {
    const allMoves = document.querySelectorAll('move[p]');
    const movesUpToPath = [];
    let foundTargetMove = false;

    for (const moveEl of allMoves) {
      const movePath = moveEl.getAttribute('p');
      const san = moveEl.querySelector('san')?.textContent;

      if (san) {
        movesUpToPath.push({ path: movePath, san: san });
      }

      if (path.startsWith(movePath) || movePath === path) {
        if (movePath === path) {
          foundTargetMove = true;
          break;
        }
      }
    }

    if (!foundTargetMove) {
      movesUpToPath.length = 0;
      for (const moveEl of allMoves) {
        const movePath = moveEl.getAttribute('p');
        const san = moveEl.querySelector('san')?.textContent;

        if (path.startsWith(movePath) && san) {
          movesUpToPath.push({ path: movePath, san: san });
        }
      }
    }

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

    return {
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
  }

  // Show repertoire selection submenu
  async function showRepertoireMenu(parentMenu, path) {
    console.log('[REPERTOIRE] Showing repertoire selection menu');

    // Fetch repertoires
    const repertoires = await fetchRepertoires();
    console.log('[REPERTOIRE] Fetched repertoires:', repertoires);

    // Create submenu container
    const submenu = document.createElement('div');
    submenu.className = 'repertoire-submenu';
    submenu.style.cssText = `
      position: fixed;
      background: #2e2a24;
      border: 1px solid #3d3933;
      border-radius: 4px;
      padding: 8px 0;
      z-index: 10001;
      min-width: 250px;
      max-width: 350px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.5);
      font-family: 'Noto Sans', sans-serif;
    `;

    // Position submenu next to parent menu
    const rect = parentMenu.getBoundingClientRect();
    submenu.style.left = `${rect.right + 5}px`;
    submenu.style.top = `${rect.top}px`;

    // Search input
    const searchContainer = document.createElement('div');
    searchContainer.style.cssText = 'padding: 4px 8px; border-bottom: 1px solid #3d3933;';

    const searchInput = document.createElement('input');
    searchInput.type = 'text';
    searchInput.placeholder = 'Search repertoires...';
    searchInput.style.cssText = `
      width: 100%;
      padding: 6px 8px;
      background: #3d3933;
      border: 1px solid #4d4944;
      border-radius: 3px;
      color: #d0d0d0;
      font-size: 13px;
      outline: none;
    `;
    searchContainer.appendChild(searchInput);
    submenu.appendChild(searchContainer);

    // Repertoire list container
    const listContainer = document.createElement('div');
    listContainer.style.cssText = 'max-height: 400px; overflow-y: auto;';
    submenu.appendChild(listContainer);

    // Function to render repertoire list
    function renderList(items) {
      listContainer.innerHTML = '';

      if (items.length === 0) {
        const emptyMsg = document.createElement('div');
        emptyMsg.textContent = 'No repertoires found';
        emptyMsg.style.cssText = 'padding: 12px; color: #888; text-align: center; font-size: 13px;';
        listContainer.appendChild(emptyMsg);
        return;
      }

      // Show top 3 most recent if no search query
      const itemsToShow = searchInput.value.trim() === '' ? items.slice(0, 3) : items;

      itemsToShow.forEach((rep, index) => {
        const item = document.createElement('a');
        item.className = 'action';
        item.style.cssText = `
          display: block;
          padding: 10px 12px;
          cursor: pointer;
          color: #d0d0d0;
          text-decoration: none;
          font-size: 14px;
          border-bottom: 1px solid #3d3933;
        `;
        item.innerHTML = `
          <div style="font-weight: 500;">${rep.name}.pgn</div>
          <div style="font-size: 11px; color: #888; margin-top: 2px;">${rep.lineCount} lines</div>
        `;

        item.onmouseenter = () => item.style.background = '#3d3933';
        item.onmouseleave = () => item.style.background = 'transparent';

        item.onclick = async (e) => {
          e.preventDefault();
          e.stopPropagation();

          try {
            const lineData = extractLineDataFromDOM(path);
            const result = await sendToRepertoire(lineData, rep.filename);

            if (result.success) {
              if (result.data?.status === 'duplicate') {
                showNotification(`Line already in ${rep.name}`);
              } else {
                showNotification(`Added to ${rep.name}!`);
              }
            } else {
              showNotification(`Failed: ${result.error}`, true);
            }
          } catch (error) {
            console.error('[REPERTOIRE] Error:', error);
            showNotification(`Error: ${error.message}`, true);
          }

          submenu.remove();
          parentMenu.remove();
        };

        listContainer.appendChild(item);
      });
    }

    // Initial render with top 3
    renderList(repertoires);

    // Search functionality
    searchInput.oninput = () => {
      const query = searchInput.value.trim();
      const filtered = filterRepertoires(repertoires, query);
      renderList(filtered);
    };

    // Close submenu when clicking outside
    function closeHandler(e) {
      if (!submenu.contains(e.target) && !parentMenu.contains(e.target)) {
        submenu.remove();
        document.removeEventListener('click', closeHandler);
      }
    }
    setTimeout(() => document.addEventListener('click', closeHandler), 100);

    document.body.appendChild(submenu);

    // Focus search input
    searchInput.focus();
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
    button.innerHTML = '<i data-icon=""></i>Add to repertoire...';
    button.style.cssText = 'cursor: pointer;';
    console.log('[REPERTOIRE] Created button element:', button);

    button.onclick = async (e) => {
      console.log('[REPERTOIRE] Button clicked!');
      e.preventDefault();
      e.stopPropagation();

      try {
        await showRepertoireMenu(menu, path);
      } catch (error) {
        console.error('[REPERTOIRE] Error:', error);
        showNotification(`Error: ${error.message}`, true);
      }
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
