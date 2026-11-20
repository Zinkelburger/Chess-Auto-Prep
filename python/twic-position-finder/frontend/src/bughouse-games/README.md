<!-- The data contract for /bughouse-games, copied verbatim from the builder's
     GAMES_CONTRACT.md (HypeBeast repo). It is fixed: change it only together
     with the builder. How the page reads it is at the end. -->

# Annotated bughouse games: data contract (version 1)

Two programs meet at this format. The builder (HypeBeast repo) writes it from
arena match logs; the viewer page (Chess-Auto-Prep website, `/bughouse-games`)
reads it. The viewer never generates moves: every position it shows is a FEN
in the data.

Served from `/bughouse-games/`: `index.json` and one file per game.

## index.json

```json
{
  "version": 1,
  "generated": "2026-11-19",
  "source": "one sentence saying what these games are",
  "games": [
    {
      "id": "v7-vs-v110-sanity-r07",
      "file": "v7-vs-v110-sanity-r07-0123456789.json",
      "title": "short title written by the annotator",
      "summary": "one to three sentences",
      "event": "HypeBeast 1.1.1 against HypeBeast 1.1.0, 500,000 nodes a move",
      "date": "2026-11-17",
      "seats": {"Awhite": "HypeBeast 1.1.1", "Ablack": "HypeBeast 1.1.0", "Bwhite": "HypeBeast 1.1.0", "Bblack": "HypeBeast 1.1.1"},
      "winner": 0,
      "how": "checkmate",
      "moves": 97,
      "notes": 11
    }
  ]
}
```

`file` is `<id>-<first 10 hex of the file's sha256>.json` so it can be cached
immutably. `id` matches `^[A-Za-z0-9][\w-]{0,63}$` and is the deep link
(`/bughouse-games#<id>`, and `#<id>:<move index>` for one move).
`winner` is the index into `teams` (below), or null for a draw.
`moves` is the number of half-moves on both boards; `notes` the number of
moves that carry a note.

## Game file

```json
{
  "version": 1,
  "id": "...", "title": "...", "summary": "...", "event": "...", "date": "...",
  "seats": {"Awhite": "...", "Ablack": "...", "Bwhite": "...", "Bblack": "..."},
  "teams": [["Awhite", "Bblack"], ["Ablack", "Bwhite"]],
  "result": {"winner": 0, "how": "checkmate", "board": "A", "text": "White on board A mates; the team of A-White and B-Black wins."},
  "initial_clock": 120,
  "start": {"A": "<fen>", "B": "<fen>"},
  "moves": [ Move, ... ]
}
```

### Move

In the order the moves were made across both boards.

```json
{
  "i": 57,
  "board": "A",
  "seat": "Ablack",
  "num": 15,
  "uci": "n@f3",
  "san": "N@f3+",
  "fen": {"A": "<fen after the move>", "B": "<fen of the other board at that moment>"},
  "t": 61.4,
  "clocks": {"Awhite": 88.2, "Ablack": 90.1, "Bwhite": 91.0, "Bblack": 87.5},
  "eval": -235,
  "mate": null,
  "book": false,
  "waited": null,
  "glyph": null,
  "note": null,
  "lines": [ Line, ... ]
}
```

- `i` counts from 0. `num` is the move number on that board.
- `uci`: drops are written `N@f3` (upper-case piece letter).
- `fen`: both boards after this move. Each is one board's FEN with both
  reserves in the form the website's `readBoard`
  (`python/twic-position-finder/frontend/src/bughouse/setup.ts`) reads.
- `t`: game time in seconds when the move was made. `clocks`: seconds left
  for each seat after the move. Either may be null when the log has none.
- `eval`: the mover's engine score for its own board in centipawns from that
  board's White side (positive is good for that board's White), or null.
  `mate`: moves to a forced mate on that board with the same sign rule, or
  null. Opening moves that come from the opening book have `book: true` and
  no eval.
- `waited`: null, or `{"seconds": 6.5, "why": "partner_mate"}` when the seat
  sat (declined to move) before making this move. `why` is one of a short
  list of codes the builder documents; the viewer shows a fixed phrase per
  code and falls back to "waited" for a code it does not know.
- `glyph`: null or one of `!`, `!!`, `?`, `??`, `!?`, `?!`.
- `note`: null or plain text (no markup) about this move.
- `lines`: zero or more variations starting from the position *before* this
  move (so a line may show what could have been played instead) or *after*
  it (what follows); see `from`.

### Line

A variation on one board. The other board is not moved.

```json
{
  "id": "m57-a",
  "kind": "instead",
  "from": "before",
  "board": "A",
  "start": "<this board's fen where the line begins>",
  "assume": "",
  "moves": [{"uci": "g8f6", "san": "Nf6", "fen": "<this board after it>"}, ...],
  "eval": 140,
  "mate": null,
  "note": null
}
```

- `kind`: `played` (the engine's expected continuation after the move it
  made), `instead` (another first move and the engine's answer to it),
  `threat` (what the other side does if given a free move), `arrives`
  (the line the engine planned for the case that `assume` reaches a hand).
- `from`: `before` or `after` this move.
- `assume`: pieces the line supposes the partner delivers first, as letters
  in FEN case (`N` a knight for White on this board, `p` a pawn for Black),
  already present in `start`'s reserve. Empty when the line uses only what is
  on the board and in hand.
- `eval` / `mate`: the engine's score at the end of the search that produced
  the line, same sign rule as a move's.
- `note`: null or plain text.

## Rules for text

`title`, `summary` and every `note` are plain text written by the annotator.
Moves inside text are in SAN exactly as they appear in the data (`N@f3+`,
`Qxd4`). Everything else in the file comes from the builder.

## How the page reads it

- `games.ts` checks every file against this contract. A broken index entry
  or line is left out with a console warning; a game whose moves break it is
  refused whole (its positions cannot be trusted) and the page says the file
  does not follow the games format.
- The page shows each game's `title` and `summary` but not the annotation:
  every move's `note`, `glyph` and `lines` are read and checked, never shown.
- `view.ts` is where the reader is: a move (-1 is the start).
- `words.ts` has the phrases. `waited.why` codes with a phrase:
  `partner_mate`, `mated`, `deny_feed`, `wait_delivery` (the builder's four);
  any other code reads "waited N s".
- Each board's header shows the last `eval`/`mate` given on that board at or
  before the current move. Scores beyond ±20 pawns show as `>+20` / `<−20`
  (the exact number on hover); a mate is `#n`.
- The index's `source` is shown under the list's introduction.
- `public/bughouse-games/` holds the served files, written by the builder;
  replace the whole directory to update the collection. `npm run test:games`
  checks whatever is there against what the contract guarantees (contract,
  file-name hashes, the index's counts, known line kinds and wait codes);
  exact expectations use a small game
  inside `tests/games.ts`. `npm run test:games:browser` picks its games and
  moves from the files at run time.
