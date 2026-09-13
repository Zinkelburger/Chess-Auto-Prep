// Chessable page → PGN. Pure functions only: no browser APIs, no network.
//
// Loaded as a content script (globals) and by the Node test as a module.
// `extractLine` is the one function that touches DOM nodes; it only uses
// querySelectorAll / getAttribute / innerHTML / textContent so a fetched page
// parsed by DOMParser works the same as the live document.

(function (root) {
  'use strict';

  const STANDARD_START =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  // Glyph text as Chessable renders it in `.annotation` → PGN NAG numbers.
  // Mirrors the app's `kMoveNags` / `kPositionNagSymbols`.
  const MOVE_GLYPHS = {
    '!!': 3,
    '??': 4,
    '!?': 5,
    '?!': 6,
    '!': 1,
    '?': 2,
  };
  const POSITION_GLYPHS = {
    '□': 7,
    '=': 10,
    '∞': 13,
    '⩲': 14,
    '⩱': 15,
    '±': 16,
    '∓': 17,
    '+-': 18,
    '+−': 18,
    '+–': 18,
    '-+': 19,
    '−+': 19,
    '–+': 19,
    '⨀': 22,
    '⟳': 32,
    '↑': 36,
    '→': 40,
    '⇆': 132,
    'N': 146,
  };

  // Chessable's move-quality glyph, followed optionally by a position glyph.
  // Returns { nags: [...], rest: 'unrecognised text' }.
  function glyphToNags(text) {
    const nags = [];
    let rest = (text || '').replace(/\s+/g, '');
    if (!rest) return { nags, rest: '' };
    const move = /^(!!|\?\?|!\?|\?!|!|\?)/.exec(rest);
    if (move) {
      nags.push(MOVE_GLYPHS[move[1]]);
      rest = rest.slice(move[1].length);
    }
    if (rest && Object.prototype.hasOwnProperty.call(POSITION_GLYPHS, rest)) {
      nags.push(POSITION_GLYPHS[rest]);
      rest = '';
    }
    return { nags, rest };
  }

  // Chessable writes `data-move="12."` for White and `"12..."` for Black.
  function parseMoveLabel(label) {
    const m = /^\s*(\d+)\s*(\.{1,3})\s*$/.exec(label || '');
    if (!m) return null;
    return { number: parseInt(m[1], 10), isWhite: m[2] === '.' };
  }

  const ENTITIES = {
    amp: '&',
    lt: '<',
    gt: '>',
    quot: '"',
    apos: "'",
    nbsp: ' ',
    ndash: '–',
    mdash: '—',
    hellip: '…',
    lsquo: '‘',
    rsquo: '’',
    ldquo: '“',
    rdquo: '”',
  };

  function decodeEntities(text) {
    return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, name) => {
      if (name[0] === '#') {
        const code =
          name[1] === 'x' || name[1] === 'X'
            ? parseInt(name.slice(2), 16)
            : parseInt(name.slice(1), 10);
        return Number.isFinite(code) ? String.fromCodePoint(code) : whole;
      }
      const key = name.toLowerCase();
      return Object.prototype.hasOwnProperty.call(ENTITIES, key)
        ? ENTITIES[key]
        : whole;
    });
  }

  // Comment HTML → PGN comment text. Paragraph breaks (`<br><br>`, `</p>`)
  // become the double space the app reads as a Chessable paragraph break;
  // single line breaks become one space. `}` would end the comment early.
  function htmlToText(html) {
    let text = html || '';
    text = text.replace(/<\s*br\s*\/?\s*>/gi, '\n');
    text = text.replace(/<\s*\/?\s*(p|div|h[1-6]|blockquote)\b[^>]*>/gi, '\n\n');
    text = text.replace(/<\s*\/\s*li\s*>/gi, '\n\n');
    text = text.replace(/<\s*li\b[^>]*>/gi, '\n\n• ');
    text = text.replace(/<[^>]+>/g, '');
    text = decodeEntities(text);
    text = text.replace(/[ \t\u00a0]+/g, ' ');
    const paragraphs = text
      .split(/\s*\n\s*\n\s*/)
      .map((p) => p.replace(/\s*\n\s*/g, ' ').trim())
      .filter((p) => p.length > 0);
    return paragraphs.join('  ').replace(/\}/g, ')');
  }

  function escapeHeader(value) {
    return String(value == null ? '' : value)
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"')
      .replace(/[\r\n]+/g, ' ')
      .trim();
  }

  function safeFilename(name, fallback) {
    const cleaned = String(name || '')
      .replace(/[\\/:*?\"<>|\x00-\x1f]/g, '-')
      .replace(/\s+/g, ' ')
      .trim()
      .replace(/^\.+/, '');
    return (cleaned || fallback || 'chessable').slice(0, 120);
  }

  const FEN_RE =
    /\b([rnbqkpRNBQKP1-8]+(?:\/[rnbqkpRNBQKP1-8]+){7})\s+([wb])\s+(-|[KQkqA-Ha-h]{1,4})\s+(-|[a-h][36])\s+(\d+)\s+(\d+)\b/g;

  // The position before the first move. The moves only carry the position
  // *after* each of them, so a line that starts mid-game needs the page to
  // mention its start FEN somewhere (board data, inline JSON). Any FEN whose
  // side to move and move number match the first move is that position.
  // Returns null for the standard start, or when nothing on the page fits.
  function findStartFen(firstMove, pageHtml) {
    if (!firstMove) return null;
    if (firstMove.number === 1 && firstMove.isWhite) return null;
    const wantSide = firstMove.isWhite ? 'w' : 'b';
    const wantNumber = firstMove.number;
    const html = pageHtml || '';
    let m;
    FEN_RE.lastIndex = 0;
    while ((m = FEN_RE.exec(html)) !== null) {
      if (m[2] !== wantSide) continue;
      if (parseInt(m[6], 10) !== wantNumber) continue;
      return `${m[1]} ${m[2]} ${m[3]} ${m[4]} ${m[5]} ${m[6]}`;
    }
    return null;
  }

  // Join tokens with spaces, wrapping between tokens near 80 columns. A
  // comment is one token and is never broken: the app reads double spaces
  // inside it as paragraph breaks, so its bytes must survive untouched.
  function wrapMovetext(tokens, width) {
    const max = width || 79;
    const lines = [];
    let line = '';
    for (const token of tokens) {
      if (!line) {
        line = token;
      } else if (line.length + 1 + token.length > max) {
        lines.push(line);
        line = token;
      } else {
        line += ' ' + token;
      }
    }
    if (line) lines.push(line);
    return lines.join('\n');
  }

  // line: { moves: [{number, isWhite, san, nags, comment}], leadingComment,
  //         startFen }
  // headers: { event, site, white, black, ... } in Chessable-export shape:
  // chapter title in [White], variation title in [Black], Result "*".
  function buildPgn(headers, line) {
    const h = Object.assign(
      {
        Event: '?',
        Site: 'https://www.chessable.com',
        Date: '????.??.??',
        Round: '?',
        White: '?',
        Black: '?',
        Result: '*',
      },
      headers || {},
    );
    const order = ['Event', 'Site', 'Date', 'Round', 'White', 'Black', 'Result'];
    const tagLines = [];
    for (const key of order) {
      tagLines.push(`[${key} "${escapeHeader(h[key])}"]`);
    }
    if (line.startFen && line.startFen !== STANDARD_START) {
      tagLines.push('[SetUp "1"]');
      tagLines.push(`[FEN "${escapeHeader(line.startFen)}"]`);
    }
    for (const key of Object.keys(h)) {
      if (order.includes(key) || key === 'SetUp' || key === 'FEN') continue;
      tagLines.push(`[${key} "${escapeHeader(h[key])}"]`);
    }

    const tokens = [];
    if (line.leadingComment) tokens.push(`{${line.leadingComment}}`);
    let afterComment = !!line.leadingComment;
    let first = true;
    for (const move of line.moves) {
      if (move.isWhite) {
        tokens.push(`${move.number}.`);
      } else if (first || afterComment) {
        tokens.push(`${move.number}...`);
      }
      tokens.push(move.san);
      for (const nag of move.nags || []) tokens.push(`$${nag}`);
      afterComment = false;
      if (move.comment) {
        tokens.push(`{${move.comment}}`);
        afterComment = true;
      }
      first = false;
    }
    tokens.push(h.Result || '*');
    return `${tagLines.join('\n')}\n\n${wrapMovetext(tokens)}\n`;
  }

  // Read one Chessable line out of a `#theOpeningMoves` container (live or
  // parsed). Comments attach to the move they follow; text before the first
  // move becomes the leading comment. Unknown annotation glyphs are kept as
  // text at the start of the move's comment so nothing is silently lost.
  function extractLine(container, pageHtml) {
    const moves = [];
    let leading = [];
    let plyCounter = 0;
    const nodes = container.querySelectorAll(
      '.whiteMove, .blackMove, .commentInMove',
    );
    for (const node of nodes) {
      const cls = node.getAttribute('class') || '';
      if (/\bcommentInMove\b/.test(cls)) {
        const inner = node.querySelector('.commentInVariation');
        const text = htmlToText((inner || node).innerHTML);
        if (!text) continue;
        if (moves.length === 0) leading.push(text);
        else moves[moves.length - 1].commentParts.push(text);
        continue;
      }
      const isWhiteClass = /\bwhiteMove\b/.test(cls);
      let label = parseMoveLabel(node.getAttribute('data-move'));
      if (!label) {
        label = {
          number: Math.floor(plyCounter / 2) + 1,
          isWhite: isWhiteClass,
        };
      }
      plyCounter++;
      let san = (node.getAttribute('data-san') || '').trim();
      if (!san) {
        const clone = node.cloneNode(true);
        for (const a of clone.querySelectorAll('.annotation')) a.remove();
        san = (clone.textContent || '').trim();
      }
      const glyphs = [];
      const suffix = /([!?]+)$/.exec(san);
      if (suffix) {
        glyphs.push(suffix[1]);
        san = san.slice(0, -suffix[1].length);
      }
      for (const a of node.querySelectorAll('.annotation')) {
        const g = (a.textContent || '').trim();
        if (g) glyphs.push(g);
      }
      const nags = [];
      const unknown = [];
      for (const g of glyphs) {
        const parsed = glyphToNags(g);
        for (const n of parsed.nags) if (!nags.includes(n)) nags.push(n);
        if (parsed.rest) unknown.push(parsed.rest);
      }
      moves.push({
        number: label.number,
        isWhite: label.isWhite,
        san,
        fen: node.getAttribute('data-fen') || '',
        nags,
        commentParts: unknown.length ? [unknown.join(' ')] : [],
      });
    }
    for (const move of moves) {
      move.comment = move.commentParts.join('  ');
      delete move.commentParts;
    }
    const startFen = moves.length ? findStartFen(moves[0], pageHtml) : null;
    return {
      moves,
      leadingComment: leading.join('  '),
      startFen,
    };
  }

  const api = {
    STANDARD_START,
    glyphToNags,
    parseMoveLabel,
    decodeEntities,
    htmlToText,
    escapeHeader,
    safeFilename,
    findStartFen,
    wrapMovetext,
    buildPgn,
    extractLine,
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else {
    root.ChessablePgn = api;
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
