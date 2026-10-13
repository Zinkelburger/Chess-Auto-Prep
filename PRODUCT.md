# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Rated club and tournament players preparing for over-the-board events: the
owner first, and players like them. They build and maintain opening
repertoires, drill them, review their own games, and prepare for named
opponents before a round. They are comfortable with PGN files, engines and
opening explorers, and they sit at a desk for long sessions with a mouse and
keyboard. They are chess experts, not programmers: a setting that needs a
programmer to understand it is explained in one plain sentence or dropped.

## Product Purpose

One desktop workspace for a tournament player's preparation: build an opening
repertoire, train it until it sticks, check it against real games, and study
the people you will face. Success is a player sitting down at the board
already knowing the positions their opponents are likely to reach, with their
work kept safely in files they own.

## Positioning

Two things together, which neighbouring products (ChessBase, Chessable, Lichess
studies, Chessbook) do not offer in one place:

- **Repertoires computed for the replies humans actually play.** The generator
  runs expectimax over engine evaluation and human move probabilities, so a
  book covers what opponents at the player's level really play instead of
  following the engine's top line.
- **One offline workspace on files the player owns.** Viewer, builder, trainer,
  tactics from the player's own games, opponent prep and game databases share
  one board and one move tree, working on plain PGN files and local databases.
  No account and no subscription are needed to use it.

## Operating Context

- A Flutter desktop app for Linux, Windows and macOS with one design language
  of its own on all three. It is not a website and follows neither the iOS nor
  the Android guidelines; the platform field above has no desktop value, so
  read `web` there as "not a mobile platform".
- This record covers the desktop app only. chessautoprep.com is a separate
  surface without a record yet.
- Installed from a release file per system (setup.exe, .deb, .rpm, .flatpak,
  macOS zip); Stockfish and Maia are bundled. Updates are offered under
  Settings on Windows and Linux.
- The player's work lives in their Documents folder as PGN: repertoires and
  courses (one file per course, chapters inside), studies, tactics sets and
  training records. Master games live in one local database.
- Optional online sources: Lichess and chess.com accounts for downloading the
  player's own and opponents' games, the Lichess opening explorer (needs the
  player's token), ChessDB, and TWIC for master games. Downloaded games are
  cached, so the app keeps working offline.
- Modes, by their exact names: Repertoire builder, Opening books, PGN Viewer,
  Repertoire trainer, Study, Tactics, My games, Player analysis, Players &
  prep, Databases, Engine tournament, and Bughouse lab (shown only when its
  engine assets are present).
- Heavy work (generation, game review, engine matches) runs for minutes to
  hours on the player's own CPU while they keep using the app.
- Agent-driven research (opponent identity, pairings, scraping) lives in the
  companion MCP tools and hands files to the app; it is not an in-app surface.

## Capabilities and Constraints

- Every mode shares one board, move tree, document session and
  engine/explorer composition. New capability goes inside the mode the player
  already uses for that kind of work; a new mode needs a strong reason.
- Dark theme only. There is no light or system theme and no appearance setting.
- Search values are precomputed and stored. The app shows a stored value or
  says the position is not in the tree. The Bughouse lab also has an explicit
  local Expectimax action: it searches the selected board with CrazyAra policy
  probabilities and Hivemind evaluations, saves both colour values together,
  and automatically shows compatible saved results on later visits.
- Saving follows the Obsidian model: debounced, one write per burst, backup
  then atomic replace. A problem affects only the item involved; data that
  cannot be read is quarantined and logged, never deleted, and never blocks
  the rest of the app.
- A file outside Documents opens read-only; edits to it are held and Save
  asks where to put them.
- Keyboard bindings come from one table, shown in tooltips and in Settings.
- The app is unsigned on Windows and macOS. macOS is supported but not a
  priority.
- English only; there is no localization layer.

## Brand Commitments

- Name: Chess Auto Prep. Licence: AGPL-3.0.
- The mode is "PGN Viewer", not "Games". Mode names above are fixed.
- Voice: concise and behaviour-first. A tooltip's first sentence says what the
  control does; an optional second says what the default or an extreme means.
  No rationale, no history, no status sentences, no filler empty states.
- No invented presets or bundled "style" options. Options that cannot apply
  are hidden with a one-line reason, not shown greyed out.
- Colour and icons only where they tell the player something the text does
  not (solved or failed, a mistake marker, a state). No decorative colour, no
  decorative icons.
- No dropdown menus the player cannot type into. Choices are typeable fields,
  steppers or segmented buttons.
- Reading views do not shift: fixed-height panes, one type size, no duplicate
  controls.
- Installing is one double-click and at most one yes/no prompt.

## Evidence on Hand

- The running app, driven headless with disposable data:
  `python3 scripts/app_driver.py start`.
- Component and data-flow reference: `docs/COMPONENT_MAP.md`. Per-mode specs
  and screenshots: `docs/v2/features/`.
- Algorithm detail for the generator: `docs/ALGORITHM.md`.
- Theme tokens and shared controls: `lib/ui/theme.dart`, `lib/ui/`.
- Wireframe pages the owner liked: `docs/design/`.
- Absent, and not to be fabricated: user counts, testimonials, benchmarks
  against other products, pricing, and any claim about playing-strength gains.

## Product Principles

1. **The board is the product.** Every mode is a way of working on a position
   and its moves. Text-heavy, board-less screens do not belong.
2. **Prepare for people, not engines.** Show what opponents actually play and
   what the player's own games reveal. Analysis appears when it is news, not
   on every move.
3. **The player's files are sacred.** Never lose work, and never lock the app
   to protect it.
4. **Fewer, plainer controls.** One knob per resource, a home for every
   setting, wording a chess player understands without a manual.
5. **Calm for long sessions.** Stable layouts, quiet colour, nothing that moves
   or changes size while the player is reading.
