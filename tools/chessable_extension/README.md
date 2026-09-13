# Chessable to PGN browser extension

Saves lines from a Chessable course you own as PGN files that Chess Auto Prep
reads as a course: chapter title in `[White]`, variation title in `[Black]`,
`[Result "*"]`, comments in braces and Chessable's `!?`/`⩱` glyphs as NAGs.
The code lives in this folder; nothing is built or bundled.

## Install

Chrome / Chromium / Edge / Brave:

1. Open `chrome://extensions`, turn on **Developer mode**.
2. **Load unpacked** and pick this folder (`tools/chessable_extension`).

Firefox:

1. Open `about:debugging#/runtime/this-firefox`.
2. **Load Temporary Add-on…** and pick `manifest.json` in this folder.
   Temporary add-ons are gone after a restart; load it again when needed.

## Use

A small **Chessable → PGN** panel appears at the bottom right of Chessable
pages.

| Page | Button | Result |
|---|---|---|
| `/variation/<id>/` | Download this line | one-game PGN of the moves shown |
| `/course/<id>/<n>` (chapter) | Download chapter | every variation in that chapter |
| `/course/<id>/` or a chapter page | Download course | every chapter, every variation |

Files land in the browser's normal download folder. Move a course file into
the app's repertoire folder and the trainer groups it by chapter.

Course downloads walk the site one page at a time (about one page per
second). The panel shows the chapter and line in progress and a **Cancel**
button. When Chessable serves the moves in the page HTML, this happens in the
background without leaving the page. If it does not, the extension navigates
the tab through the course itself and returns to where it started; its place
is kept in extension storage, so a reload continues rather than restarts.

## Limits

- Only content you can open on Chessable is saved; a locked variation is
  written from its move preview without comments and listed in the summary.
- A variation that starts from a set-up position is written with a `[FEN]`
  header only when the page reveals that position. The summary names lines
  where it did not.
- Chessable's rich comment formatting (headings, quotes, links) is flattened
  to text. Paragraph breaks become the double space the app already reads.

## Test

```sh
node tools/chessable_extension/test_pgn.js
python3 tools/test_chessable_extension.py   # also checks manifest and files
```

`tools/chessable_extension/fixture/variation.html` is a copy of a variation
page's move list; `test_pgn.js` runs `extractLine` against it in a headless
Chrome when `google-chrome` or `chromium` is installed, otherwise the DOM step
is skipped and only the pure functions are tested.
