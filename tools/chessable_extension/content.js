// Chessable → PGN content script.
//
// Adds a small panel to chessable.com pages:
//   - on a variation page: "Download this line"
//   - on a course or chapter page: "Download course" / "Download chapter"
//
// Course downloads walk the course the way a reader would: course page →
// each chapter box → each variation card → the variation's `#theOpeningMoves`.
// Pages are fetched in the background with the user's own login when the
// server returns the moves in the HTML; when it does not (client-rendered),
// the walker navigates the tab from page to page instead, keeping its place
// in extension storage so it survives every reload.

(function () {
  'use strict';

  const P = globalThis.ChessablePgn;
  const ext = globalThis.browser || globalThis.chrome;
  const JOB_KEY = 'chessablePgnJob';
  const FETCH_DELAY_MS = 800;
  const WAIT_FOR_DOM_MS = 30000;
  const NAVIGATING = Symbol('navigating');

  // ---------------------------------------------------------------- storage

  function storageGet(key) {
    return new Promise((resolve) => {
      try {
        const r = ext.storage.local.get(key, (items) => resolve(items || {}));
        if (r && typeof r.then === 'function') r.then(resolve);
      } catch (_) {
        resolve({});
      }
    });
  }

  function storageSet(obj) {
    return new Promise((resolve) => {
      try {
        const r = ext.storage.local.set(obj, () => resolve());
        if (r && typeof r.then === 'function') r.then(resolve);
      } catch (_) {
        resolve();
      }
    });
  }

  function storageRemove(key) {
    return new Promise((resolve) => {
      try {
        const r = ext.storage.local.remove(key, () => resolve());
        if (r && typeof r.then === 'function') r.then(resolve);
      } catch (_) {
        resolve();
      }
    });
  }

  // -------------------------------------------------------------- page bits

  function pathOf(url) {
    try {
      return new URL(url, location.origin).pathname.replace(/\/+$/, '');
    } catch (_) {
      return url;
    }
  }

  function absolute(href) {
    return new URL(href, location.origin).toString();
  }

  function firstText(doc, selectors) {
    for (const sel of selectors) {
      const el = doc.querySelector(sel);
      if (el) {
        const text = (el.getAttribute('title') || el.textContent || '').trim();
        if (text) return text;
      }
    }
    return '';
  }

  function pageTitle(doc) {
    const raw = (doc.querySelector('title') || {}).textContent || '';
    return raw.replace(/\s*[-|–]\s*Chessable.*$/i, '').trim();
  }

  function courseIdFromPath(pathname) {
    const m = /^\/(?:course|learn|practice)\/(\d+)/.exec(pathname);
    return m ? m[1] : null;
  }

  function chapterIndexFromPath(pathname) {
    const m = /^\/course\/\d+\/(\d+)/.exec(pathname);
    return m ? m[1] : null;
  }

  function courseUrl(courseId) {
    return `${location.origin}/course/${courseId}/`;
  }

  function courseTitleOf(doc) {
    return (
      firstText(doc, [
        '[data-testid="courseTitle"]',
        '.courseTitle',
        '.course-title',
        'h1',
      ]) || pageTitle(doc)
    );
  }

  function variationTitleOf(doc) {
    return (
      firstText(doc, [
        '[data-testid="variationTitle"]',
        '.variationTitle',
        '.openingTitle',
        '#openingTitle',
        '.opening-title',
        'h1',
      ]) || pageTitle(doc)
    );
  }

  function readChapters(doc) {
    const boxes = doc.querySelectorAll('#chapterBoxes a.levelBox');
    const chapters = [];
    for (const a of boxes) {
      const href = a.getAttribute('href');
      if (!href) continue;
      const title =
        (a.querySelector('.title') || {}).textContent || a.textContent || '';
      chapters.push({ title: title.trim(), url: absolute(href) });
    }
    return chapters;
  }

  function readVariations(doc) {
    const cards = doc.querySelectorAll(
      '#variations .variation-card, .variation-card',
    );
    const seen = new Set();
    const variations = [];
    for (const card of cards) {
      const link =
        card.querySelector('a.variation-card__name') ||
        card.querySelector('a[href*="/variation/"]');
      if (!link) continue;
      const url = absolute(link.getAttribute('href'));
      if (seen.has(url)) continue;
      seen.add(url);
      const previewEl = card.querySelector('.variation-card__moves');
      variations.push({
        title: (link.getAttribute('title') || link.textContent || '').trim(),
        url,
        preview: previewEl ? previewEl.textContent.trim() : '',
      });
    }
    return variations;
  }

  function movesContainer(doc) {
    const c = doc.querySelector('#theOpeningMoves');
    if (!c) return null;
    return c.querySelector('.whiteMove, .blackMove') ? c : null;
  }

  // A preview line like "1.e4 e5 2.Nf3 Nc6" → moves without comments, for
  // a variation whose page holds no moves (locked or failed to load).
  function lineFromPreview(preview) {
    const moves = [];
    const tokens = preview.split(/\s+/).filter(Boolean);
    let number = 1;
    let isWhite = true;
    for (const raw of tokens) {
      let token = raw;
      const m = /^(\d+)(\.{1,3})(.*)$/.exec(token);
      if (m) {
        number = parseInt(m[1], 10);
        isWhite = m[2] === '.';
        token = m[3];
        if (!token) continue;
      }
      const suffix = /([!?]+)$/.exec(token);
      const nags = suffix ? P.glyphToNags(suffix[1]).nags : [];
      const san = suffix ? token.slice(0, -suffix[1].length) : token;
      moves.push({ number, isWhite, san, nags, comment: '' });
      if (!isWhite) number++;
      isWhite = !isWhite;
    }
    return { moves, leadingComment: '', startFen: null };
  }

  function download(text, filename) {
    const blob = new Blob([text], { type: 'application/x-chess-pgn' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => {
      a.remove();
      URL.revokeObjectURL(url);
    }, 2000);
  }

  function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
  }

  async function waitFor(check, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const value = check();
      if (value) return value;
      if (Date.now() > deadline) return null;
      await sleep(400);
    }
  }

  // ------------------------------------------------------------------ panel

  let panel = null;
  let statusEl = null;
  let buttonsEl = null;

  function ensurePanel() {
    if (panel) return panel;
    panel = document.createElement('div');
    panel.id = 'chessable-pgn-panel';
    panel.style.cssText = [
      'position:fixed',
      'right:16px',
      'bottom:16px',
      'z-index:2147483646',
      'background:#1f2430',
      'color:#e6e6e6',
      'font:13px/1.4 system-ui,sans-serif',
      'border-radius:8px',
      'box-shadow:0 4px 16px rgba(0,0,0,.4)',
      'padding:10px 12px',
      'max-width:320px',
    ].join(';');
    const title = document.createElement('div');
    title.textContent = 'Chessable → PGN';
    title.style.cssText = 'font-weight:600;margin-bottom:6px';
    buttonsEl = document.createElement('div');
    buttonsEl.style.cssText = 'display:flex;flex-wrap:wrap;gap:6px';
    statusEl = document.createElement('div');
    statusEl.style.cssText =
      'margin-top:6px;color:#b8c0d0;white-space:pre-wrap;word-break:break-word';
    panel.append(title, buttonsEl, statusEl);
    document.body.appendChild(panel);
    return panel;
  }

  function addButton(label, onClick) {
    ensurePanel();
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.style.cssText = [
      'background:#3b82f6',
      'color:#fff',
      'border:0',
      'border-radius:6px',
      'padding:6px 10px',
      'cursor:pointer',
      'font:inherit',
    ].join(';');
    b.addEventListener('click', () => {
      onClick(b).catch((err) => setStatus(`Error: ${err && err.message}`));
    });
    buttonsEl.appendChild(b);
    return b;
  }

  function setStatus(text) {
    ensurePanel();
    statusEl.textContent = text;
  }

  function clearButtons() {
    ensurePanel();
    buttonsEl.textContent = '';
  }

  // --------------------------------------------------------------- one line

  // A line whose first move is not White's first and whose page revealed no
  // start FEN: the PGN is written from the standard start and will be wrong.
  function startsMidGameWithoutFen(line) {
    const first = line.moves[0];
    return !line.startFen && !(first.number === 1 && first.isWhite);
  }

  function lineFromDoc(doc, html) {
    const container = movesContainer(doc);
    if (!container) return null;
    return P.extractLine(container, html || doc.documentElement.outerHTML);
  }

  async function downloadCurrentLine() {
    const line = lineFromDoc(document);
    if (!line || !line.moves.length) {
      setStatus('No moves found on this page.');
      return;
    }
    const title = variationTitleOf(document);
    // A one-game file has no chapter structure, so the app names the line
    // from [Opening]; [Black] keeps the course shape for later merging.
    const pgn = P.buildPgn(
      {
        Event: pageTitle(document) || 'Chessable',
        Site: location.href,
        White: '?',
        Black: title || '?',
        Opening: title || '?',
      },
      line,
    );
    download(pgn, `${P.safeFilename(title, 'variation')}.pgn`);
    setStatus(
      `Saved ${line.moves.length} moves` +
        (startsMidGameWithoutFen(line)
          ? ' (start position not found on page; line starts mid-game)'
          : '') +
        '.',
    );
  }

  // ------------------------------------------------------------ course walk

  // job = { courseId, courseUrl, courseTitle, onlyChapterPath, returnUrl,
  //         chapters: [{title, url, variations: null|[...]}],
  //         chapterIndex, variationIndex, games: [], issues: [],
  //         navigate: false }

  async function saveJob(job) {
    await storageSet({ [JOB_KEY]: job });
  }

  async function loadJob() {
    const items = await storageGet(JOB_KEY);
    return items[JOB_KEY] || null;
  }

  async function cancelJob() {
    await storageRemove(JOB_KEY);
    clearButtons();
    setStatus('Cancelled.');
    installPageButtons();
  }

  // Get a parsed document for `url` that satisfies `valid(doc)`.
  // Fetch first; if the fetched HTML lacks the content, switch the job to
  // navigation and drive the tab there instead. Returns NAVIGATING when the
  // tab is about to leave, null when the page loaded without the content.
  async function obtainDoc(job, url, valid) {
    if (!job.navigate) {
      await sleep(FETCH_DELAY_MS);
      let html = '';
      try {
        const res = await fetch(url, { credentials: 'include' });
        html = await res.text();
      } catch (_) {
        html = '';
      }
      if (html) {
        const doc = new DOMParser().parseFromString(html, 'text/html');
        if (valid(doc)) return { doc, html };
      }
      job.navigate = true;
      await saveJob(job);
    }
    if (pathOf(location.href) === pathOf(url)) {
      const ok = await waitFor(() => valid(document), WAIT_FOR_DOM_MS);
      if (!ok) return null;
      return { doc: document, html: document.documentElement.outerHTML };
    }
    // A page that never arrives (a redirect to login, a removed line) must
    // not bounce the tab back and forth forever.
    job.navAttempts = job.navAttempts || {};
    const attempts = (job.navAttempts[url] || 0) + 1;
    job.navAttempts[url] = attempts;
    if (attempts > 2) return null;
    await saveJob(job);
    location.href = url;
    return NAVIGATING;
  }

  function finishedJobFilename(job) {
    if (job.onlyChapterPath) {
      const chapter = job.chapters.find(
        (c) => pathOf(c.url) === job.onlyChapterPath,
      );
      const name = `${job.courseTitle} - ${chapter ? chapter.title : 'chapter'}`;
      return `${P.safeFilename(name, 'chapter')}.pgn`;
    }
    return `${P.safeFilename(job.courseTitle, 'course')}.pgn`;
  }

  async function runJob(job) {
    clearButtons();
    addButton('Cancel', async () => cancelJob());

    for (;;) {
      if (job.chapterIndex >= job.chapters.length) break;
      const chapter = job.chapters[job.chapterIndex];

      if (chapter.variations === null) {
        setStatus(`Reading chapter ${job.chapterIndex + 1}/${job.chapters.length}: ${chapter.title}`);
        const got = await obtainDoc(job, chapter.url, (d) =>
          readVariations(d).length > 0 || d.querySelector('#variations'),
        );
        if (got === NAVIGATING) return;
        chapter.variations = got ? readVariations(got.doc) : [];
        if (!got) job.issues.push(`Chapter "${chapter.title}": could not load its variation list.`);
        job.variationIndex = 0;
        await saveJob(job);
        continue;
      }

      if (job.variationIndex >= chapter.variations.length) {
        job.chapterIndex++;
        job.variationIndex = 0;
        await saveJob(job);
        continue;
      }

      const variation = chapter.variations[job.variationIndex];
      setStatus(
        `Chapter ${job.chapterIndex + 1}/${job.chapters.length}: ${chapter.title}\n` +
          `Line ${job.variationIndex + 1}/${chapter.variations.length}: ${variation.title}\n` +
          `${job.games.length} lines saved so far`,
      );
      const got = await obtainDoc(job, variation.url, (d) => movesContainer(d));
      if (got === NAVIGATING) return;

      let line = got ? lineFromDoc(got.doc, got.html) : null;
      if (!line || !line.moves.length) {
        if (variation.preview) {
          line = lineFromPreview(variation.preview);
          job.issues.push(`"${variation.title}": page had no moves; saved the preview line without comments.`);
        } else {
          job.issues.push(`"${variation.title}": page had no moves; skipped.`);
        }
      } else if (startsMidGameWithoutFen(line)) {
        job.issues.push(`"${variation.title}": starts mid-game and the page did not reveal the start position.`);
      }
      if (line && line.moves.length) {
        job.games.push(
          P.buildPgn(
            {
              Event: job.courseTitle,
              Site: variation.url,
              White: chapter.title,
              Black: variation.title,
            },
            line,
          ),
        );
      }
      job.variationIndex++;
      await saveJob(job);
    }

    const pgn = job.games.join('\n');
    download(pgn, finishedJobFilename(job));
    await storageRemove(JOB_KEY);
    clearButtons();
    const summary = [`Done: ${job.games.length} lines saved.`];
    if (job.issues.length) {
      summary.push(`${job.issues.length} note(s):`);
      summary.push(...job.issues.slice(0, 8));
      if (job.issues.length > 8) summary.push('…');
    }
    setStatus(summary.join('\n'));
    if (job.navigate && pathOf(location.href) !== pathOf(job.returnUrl)) {
      await sleep(2500);
      location.href = job.returnUrl;
      return;
    }
    installPageButtons();
  }

  async function startJob(courseId, onlyChapterPath) {
    const job = {
      courseId,
      courseUrl: courseUrl(courseId),
      courseTitle: '',
      onlyChapterPath: onlyChapterPath || null,
      returnUrl: location.href,
      chapters: null,
      chapterIndex: 0,
      variationIndex: 0,
      games: [],
      issues: [],
      navigate: false,
    };
    await saveJob(job);
    await resumeJob(job);
  }

  async function resumeJob(job) {
    clearButtons();
    addButton('Cancel', async () => cancelJob());
    if (job.chapters === null) {
      setStatus('Reading course chapters…');
      const got = await obtainDoc(job, job.courseUrl, (d) => readChapters(d).length > 0);
      if (got === NAVIGATING) return;
      if (!got) {
        await storageRemove(JOB_KEY);
        clearButtons();
        setStatus('Could not read the chapter list from the course page.');
        installPageButtons();
        return;
      }
      job.courseTitle = courseTitleOf(got.doc) || `Chessable course ${job.courseId}`;
      let chapters = readChapters(got.doc).map((c) => ({ ...c, variations: null }));
      if (job.onlyChapterPath) {
        chapters = chapters.filter((c) => pathOf(c.url) === job.onlyChapterPath);
        if (!chapters.length) {
          await storageRemove(JOB_KEY);
          clearButtons();
          setStatus('This chapter is not listed on the course page.');
          installPageButtons();
          return;
        }
      }
      job.chapters = chapters;
      await saveJob(job);
    }
    await runJob(job);
  }

  // ------------------------------------------------------------------ setup

  function installPageButtons() {
    clearButtons();
    const path = location.pathname;
    const courseId = courseIdFromPath(path);
    const chapterIdx = chapterIndexFromPath(path);
    let any = false;

    if (movesContainer(document) || /^\/variation\//.test(path)) {
      addButton('Download this line', async () => downloadCurrentLine());
      any = true;
    }
    if (courseId && chapterIdx !== null) {
      addButton('Download chapter', async () =>
        startJob(courseId, pathOf(location.href)),
      );
      any = true;
    }
    if (courseId) {
      addButton('Download course', async () => startJob(courseId));
      any = true;
    }
    if (!any && panel) {
      panel.remove();
      panel = null;
    } else {
      setStatus('');
    }
  }

  async function main() {
    if (!P) return;
    const job = await loadJob();
    if (job) {
      ensurePanel();
      await resumeJob(job);
      return;
    }
    // React pages render the move list a moment after load.
    await waitFor(
      () => movesContainer(document) || document.querySelector('#chapterBoxes'),
      4000,
    );
    installPageButtons();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => main());
  } else {
    main();
  }
})();
