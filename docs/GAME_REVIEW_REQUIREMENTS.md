# Game review page — feature requirements for review

Status: draft for Andrew to edit. This describes what the page should do, not a final layout or implementation plan. The page may be rebuilt from scratch. The earlier PGN-menu mockups are superseded; their controls and grouping are not requirements.

**Purpose:** open a game, understand it, compare it with your preparation, and collect useful games in studies without repeatedly changing pages.

Legend: **Required** reflects the requested direction. **Proposed** is a suggested behavior to edit. **Decide** identifies an unresolved product choice. Unchecked boxes are reviewable requirements, not a record of implementation status.

## Implementation checkpoint — 7 September 2026

The `codex/games-study-workspace` change implements a quieter default: board and moves, four move-navigation buttons, collection navigation, a study action, and one labelled View menu. There are no permanent activity tabs, rating stars, always-visible engine controls, or default Play button. The existing file picker is labelled with the collection name or “Open games”.

Implemented in this change:

- Add the current game, or select multiple games from the currently filtered collection, to an existing or new study. Keep reviewing after saving without a completion popup. The destination picker offers Add new study immediately, with a dedicated name prompt. Append a batch in one file write and retain unsaved edits when the destination is already open.
- When viewing a study, offer Edit study and return to that chapter and position. Copying into another study is a secondary action.
- Keep filters accessible through one Filter games control; show matching/total counts when active. Preserve the existing detailed filter dialog.
- One View menu contains Explore this game, Solitaire chess, Customize view, Game and collection, and App settings. Contextual panels offer Back to game.
- Remember explicit engine-control, saved-graph, and playback visibility, playback speed, and continue-to-next-game choices. Restore simple defaults is available. Restoring playback visibility never starts playback.
- Show stored evaluation below the board and synchronize graph clicks with the game. Analysis handoffs keep the moves visible. Detailed move analysis remains an on-demand panel.
- Make the existing My repertoire comparison reader available for imported games as well as recent-game/tactics handoffs.

Still open for product review: membership indicators and duplicate detection; source references beyond preserved PGN headers; richer matching across multiple related repertoire chapters/lines; reading the game and several prepared lines simultaneously. The requirements below deliberately retain these ambitions. This change does not claim to implement them.

Validation: 20 focused tests pass, including study batch persistence, open-study edits, selection scope, preference reload, navigation routing, and move-reader options. Analyze and lint pass; the analyzer reports one existing informational const suggestion in `review_counterexamples_test.dart`.

Headless app checks used an isolated three-game fixture. Verified adding a two-game selection to a new study, appending to that existing study, opening the new chapter, browsing a study and returning through Edit study, position filtering (2/3 games), filtered study selection, and playback visibility after restart without autoplay. Routine success snackbars, including the Open study completion popup, have since been removed.

Review screenshots: [default reader](images/game-review/default.png), [choose games](images/game-review/study-selection.png), [optional controls](images/game-review/view-options.png), [historical added-to-study confirmation, since removed](images/game-review/study-added.png).

The variation typography work is separate (`codex/pgn-variation-flow`); this change does not edit its movetext rendering files. Shared reader changes only let the host relocate reading settings into View; the reader retains its existing standalone settings by default.

## 1. Product priorities

- [ ] **Required:** Board and played moves are the stable center of the page.
- [ ] **Required:** Grouping games into studies is a first-class workflow.
- [ ] **Required:** See relevant repertoire chapters and lines while reviewing the game, without opening Repertoire Builder just to read them.
- [ ] **Required:** Display the game's analysis graph in context, rather than requiring a separate Analysis tab.
- [ ] **Required:** Preserve useful search and filter capabilities.
- [ ] **Required:** Keep beginning-of-game, previous-move, next-move, and end-of-game controls available.
- [ ] **Required:** Play is optional and hidden initially. Remember the user's choice to show it.
- [ ] **Required:** Call the activity **Solitaire chess**.
- [ ] **Required:** Remove game star ratings from this page's proposed workflow. Studies replace ratings as the way to organize useful games.
- [ ] **Required:** Do not organize the page around the label “PGN” in the top-left corner. PGN is an import/export format, not the user's primary activity.

## 2. Simplification and customization

- [ ] **Proposed:** Each visible control should serve the current activity. Opening a game should not demand a choice of workspace, tool, or mode before the user can read it.
- [ ] **Proposed:** Use one predictable place for occasional page actions. Avoid separate ellipsis, Tools, and Reading options entry points competing on the main screen.
- [ ] **Proposed:** Do not permanently expose every optional panel as a tab. Let a meaningful action reveal the relevant content.
- [ ] **Proposed:** Remember explicitly enabled content and controls: playback control, analysis graph visibility, repertoire outline, explorer, panel sizes, and reading presentation.
- [ ] **Proposed:** These preferences persist across games and app restarts. Use one shared page configuration initially, rather than making the user configure every file separately.
- [ ] **Proposed:** Temporary navigation does not rewrite preferences. Opening a specific repertoire line from another page may reveal it for that visit without changing the saved default.
- [ ] **Proposed:** Restore visibility and preferences, not running actions. Showing Play again does not start autoplay; showing a graph does not launch a fresh full-game analysis. The live-engine on/off preference can persist separately.
- [ ] **Proposed:** Remember filters, sort order, selected game and position per source/collection, rather than applying one collection's filters silently to every game the user opens.
- [ ] **Proposed:** Provide a clearly labelled way to restore the simple default. Avoid a large dashboard designer, movable toolbar system, or many layout presets in the first version.
- [ ] **Decide:** Which optional content is visible on first use? Suggested defaults: graph when saved analysis exists; one quiet related-repertoire summary when a book is configured; expanded repertoire outline and autoplay controls initially closed.

## 3. Open and navigate games

- [ ] Open a game from the app's downloaded games, a local PGN, a study chapter, a master-game result, player analysis, or an engine tournament.
- [ ] Open or paste PGN and revisit recent files. Support a single game and a collection.
- [ ] Show players, result, date/event, source and collection/study context with readable text. Allow missing headers without broken labels.
- [ ] Navigate with **Start / Previous / Next / End** and keyboard shortcuts. Exact presentation is open; these should not require opening a menu.
- [ ] Optional Play/Pause appears after the user enables playback controls. Speed and “continue to next game” remain secondary settings. Never start playback merely because a file opens.
- [ ] Choose another game, search the collection, jump to a game number, and move to previous/next game. Clearly distinguish game navigation from move navigation.
- [ ] Preserve the game cursor when inspecting a variation or repertoire line. Provide an obvious **Back to game** action.
- [ ] Preserve variations, comments, NAGs, custom starting positions, and board annotations. Branch choices appear where relevant.
- [ ] Retain flip board, orientation preference and fullscreen reading as secondary capabilities.

## 4. Studies as the organizing system

- [ ] **Required:** Offer a discoverable, text-labelled **Add to study** action for the current game. Treat this as a primary action, not an obscure export command.
- [ ] Add to an existing study or create a new study in the same flow.
- [ ] Add a selection of games or all filtered games, with an explicit count and scope before saving. Do not silently add the entire original file.
- [ ] Each full game becomes a named chapter by default. Preserve the full game and its variations/comments/analysis annotations.
- [ ] Show which studies already contain the game and open the relevant chapter directly. Repeated additions should identify a likely duplicate rather than silently generating many copies.
- [x] Keep reviewing after adding, without a completion popup or a page switch.
- [ ] Allow a useful repertoire line or analysis variation to be added to a study, labelled distinctly from adding the full played game.
- [ ] Retain provenance: source game identity/file, original players/date, and the repertoire/chapter/line when applicable.
- [ ] **Proposed:** Existing Study remains the owner of chapter editing, ordering and training. Use its storage and add-to-study flow rather than creating another grouping system.
- [ ] **Decide:** Should adding a game create a study-owned snapshot or a live link? Suggested first version: a snapshot with a source reference, so later game analysis/imports cannot silently overwrite study edits. Track membership separately; one game can belong to multiple studies.
- [ ] **Decide:** Should a full game and its related repertoire line become adjacent chapters, or should the prepared line be inserted as a variation in the game chapter? Keep the source game and repertoire unchanged either way.

## 5. Search and filters — retained

Filters are not being removed. Their UI can be rebuilt and placed with the game collection they affect.

- [ ] Search player names and game metadata; support a player on either colour and separate as-White/as-Black restrictions.
- [ ] Preserve header filters, including date, result, event/site, ECO/opening and player Elo when the data is available.
- [ ] Preserve advanced text matching: contains, excludes, exact and regex; retain appropriate date/numeric bounds.
- [ ] Preserve position filtering from the current board, FEN or a move sequence.
- [ ] Preserve move-sequence/pattern filtering, including the existing configurable move-gap behavior.
- [ ] Combine filters, preview matching games, show matching/total counts, edit/remove conditions and clear them all.
- [ ] Keep a visible indication that filters are active when the editor is closed. A zero-result state must offer a clear way back.
- [ ] Retain file order and date sorting. Remove star-rating sorts from the new interface; do not delete existing rating metadata from users' files.
- [ ] **Proposed:** Add “in this study” / “not yet in a study” filtering once study membership is tracked.
- [ ] **Decide:** Are named saved filters useful, or is remembering each collection's last filters sufficient initially?

## 6. The game's graph and analysis

- [ ] **Required:** Show the analyzed game's evaluation graph alongside the board and movelist, without an Analysis tab.
- [ ] **Proposed placement:** a shallow, full-game graph below the board. Keep it distinct from the move-navigation row. A narrow layout can place it immediately below the moves. Verify both with real long games before finalizing.
- [ ] Plot the whole game at a useful default scale. Mark the current move, with text explaining the hovered/selected point. Do not require horizontal scrolling simply to see the shape of the game.
- [ ] Clicking the graph navigates the board and played movelist to the same ply. Clicking a move updates the graph marker.
- [ ] Reuse existing saved/imported analysis. When none exists, show a small **Analyse game** action, not a large empty panel or a settings form.
- [ ] Run full-game analysis only on request or through the user's already-enabled background analysis workflow. Show progress, cancellation and partial/failed states in place.
- [ ] Distinguish full-game analysis from the live engine evaluating the current position. Engine settings must not be necessary just to view a saved graph.
- [ ] Show key mistakes and best alternatives through graph/move selection. Keep detailed statistics and engine lines secondary to the game itself.
- [ ] **Proposed:** Mark where the game leaves preparation on the same game timeline, while distinguishing “not in my repertoire” from “bad move.”
- [ ] Never manufacture values for missing evaluations. Identify partial data; show mate scores and whose perspective the evaluation uses.
- [ ] **Proposed:** When inspecting a repertoire line, the graph continues to represent the played game. Its game marker stays anchored; speculative-line evaluations must not replace the game's history.
- [ ] Remember whether the user prefers to show the graph, including an explicit choice to hide it.

## 7. Related repertoire chapters and lines

The question is: **“Which line or lines in my repertoire are most related to what I played, and what does my preparation say from there?”** A single deviation verdict is insufficient.

- [ ] Use the user's configured White/Black repertoires automatically when the played side is known. Let the user correct the side without a recurring setup dialog.
- [ ] Attach/import a repertoire PGN directly from this page, including an external course file, without first opening Builder. Keep file selection distinct from choosing to import/copy it into app storage.
- [ ] Support multiple repertoires for the same colour. Label the source of every match.
- [ ] Show a **chapter/line outline** with relevant material first. Preserve the course's section, chapter, line and variation names where available.
- [ ] Show multiple meaningful matches. Group identical/shared continuations rather than showing one long flat list of near-duplicates. Keep their source references available.
- [ ] Let the user expand a chapter to see its lines, read comments, inspect a line on the existing board, and return to the played game at the same move.
- [ ] Preserve both contexts: the played game remains identifiable and its move list available while the prepared line is inspected. Do not silently replace the game with the repertoire PGN.
- [ ] Offer an optional **All chapters** view so the user can browse nearby preparation without leaving this page.
- [ ] **Proposed matching:** prioritize the longest exact continuation shared with the game; also recognize the same position reached by a transposition. Retain the source move order and distinguish exact-path matches from position matches.
- [ ] Explain the match in ordinary language: “same line through move 9,” “same position via another move order,” or “this chapter covers the position before your 10th move.” Avoid an unexplained similarity percentage.
- [ ] At a deviation, show what was played and the available repertoire continuations, with the correct side to move. Distinguish the opponent leaving prep, the user leaving prep, prep ending, and later re-entering prep.
- [ ] Do not call two lines a match merely because their ECO/opening names are similar. If no meaningful match exists, say so; offer broader chapter browsing without presenting it as an exact match.
- [ ] **Proposed:** Initial results answer the whole-game question and remain stable while stepping through the game. A separate “At this position” refinement may narrow them; do not constantly reorder the outline under the pointer.
- [ ] **Decide:** How should quickstarter lines, detailed theory, alternative choices and model games be ranked? Suggested default: repertoire theory first, with quickstarter/model-game sources visibly distinguished and no loss of their comments.
- [ ] Builder is an explicit **Edit this line** destination. Trainer is an explicit **Practise this line/chapter** destination. Reading and comparison happen here.
- [ ] Read-only comparison must never modify the original repertoire. Re-read changed files and report missing files clearly.

### Concrete repertoire fixture

Inspected read-only: [The Gold Standard 1.e4 - IMC.pgn](</home/anbernal/Downloads/The Gold Standard 1.e4 - IMC.pgn>).

The MCP parser reported 1,179 PGN entries with variations included and a 40-ply indexing limit. These entries must not automatically become 1,179 top-level chapter rows.

For this **illustrative test sequence, not a claim about a game Andrew played**:

`1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Bg5 e6 7. f4 Be7`

The resulting position is present in 34 source entries. The indexed continuation is `8. Qf3`; related source labels span quickstarter Sicilian material, detailed Najdorf Classical theory and a model game. This is a concrete case for a grouped chapter/line outline with provenance, not one “best chapter” or 34 undifferentiated rows. Counts are PGN-entry occurrences, not popularity statistics or 34 unique continuations.

Other available fixtures include the Accelerated Dragon, Colle, Symmetrical English and Gawain Jones repertoires in Downloads. Only the Gold Standard file was parsed for this draft. Full-depth matching and matching against an actual played game remain implementation validation work.

## 8. Other capabilities to preserve without permanent buttons

- [ ] Annotate a selected move, edit comments/NAGs, explore variations, return to mainline and discard temporary analysis marks.
- [ ] Distinguish temporary exploration from saved edits. Show the save destination and an obvious exit while editing; default to preserving external source files.
- [ ] Opening explorer: retain source/settings, move statistics, hover previews and opening a result game at the relevant position. Keep the played-game context recoverable.
- [ ] Collection opening tree: browse positions shared by the current games and see the games reaching them. Consider making “This collection” an explorer source instead of another top-level mode.
- [ ] Copy/export game or selected collection as PGN. Keep FEN/position copying where relevant.
- [ ] Preserve Scid export as an advanced file action if it remains supported; it does not need a permanent control.
- [ ] Preserve creating/seeding a repertoire from selected games as an explicit Builder handoff.
- [ ] **Solitaire chess:** choose side/setup, guess moves, use Hint/Reveal, exit, and review results. Hide answer-revealing engine/graph/repertoire content during guessing, then restore the user's prior layout afterward.
- [ ] **Decide:** Keep Solitaire chess trophies/history inside that activity, or simplify to a session result? Do not keep trophies in the collection menu merely because they already exist.

## 9. Integration with other pages

| Page/source | Expected integration |
|---|---|
| Tactics / recent-game analysis | Open the exact source game at the relevant move, reuse its stored analysis, and retain a way back to the puzzle/game list. |
| Opening review | Open the game with its deviation and related repertoire context already selected. No repeated side/book setup. |
| Studies | Add current/selected/filtered games; open the correct chapter; preserve study edits and provenance. Study remains the chapter-editing/training owner. |
| Repertoire Builder | Read chapters/lines here; open Builder only to edit/generate. Pass exact repertoire, chapter/line and position; return to the reviewed game. |
| Repertoire Trainer | Practise the selected related line/chapter without manually finding it again. Retain a return path to the game that motivated practice. |
| Player analysis | Open a selected game or filtered opponent collection with its position/filter context and source preserved. |
| Databases / master games / explorer | Open a result game at the searched position; allow adding it to a study; distinguish its source from the user's own games. |
| Engine tournament | Open the selected tournament game and result/engine metadata; use the same reader, graph and study actions. |
| File open / paste | Resolve one or many games into the same reading experience; do not create a parallel viewer interface. |

All handoffs should preserve stable game/source identity, relevant ply/position, selected study or repertoire line, and a return destination. Returning should restore the prior selection, filters and scroll/cursor state. A failed/missing destination must not discard the current game.

## 10. Text, symbols and accessibility

- [ ] Use text labels for domain actions: **Add to study**, **Related repertoire**, **Analyse game**, **Solitaire chess**. Do not invent an unexplained icon for each feature.
- [ ] Familiar navigation symbols may accompany labels/tooltips. **Decide:** use text-labelled Start/Previous/Next/End initially, or familiar arrows with optional labels? Keep accessible names and keyboard shortcuts either way.
- [ ] User-visible names describe outcomes and content. Use “PGN” only where the format matters, such as Open PGN or Export PGN.
- [ ] Keep readable typography, at least the app's 12px minimum, and normal click targets. Reduce controls rather than shrinking them.
- [ ] Do not require hovering to discover essential actions. Preserve keyboard operation and visible focus.
- [ ] Active filters, unsaved edits, running analysis and the distinction between played game and repertoire preview remain visible even with tools collapsed.

## 11. Acceptance scenarios

1. Open an already-analyzed recent game. See the game, its graph and current move without selecting an Analysis tab. Click a graph point and verify board/moves synchronize.
2. Open the same game with graph visibility disabled. It remains hidden after restart; no unwanted analysis job starts.
3. Use Start/End immediately. Enable playback controls once, restart, and find Play still available but not running.
4. Filter a collection by player/colour and position. Add only those matching games to an existing study; verify count, chapter names, membership and original files.
5. Reopen a game already saved to a study. See its membership and navigate to the exact chapter without making an accidental duplicate.
6. Attach the Gold Standard PGN and inspect the sample Najdorf sequence above. Find grouped related material and `8. Qf3`; read different lines without leaving the game page.
7. Test a real played-game/repertoire pair with an exact path, a transposition, multiple matching chapters, a deviation, an ended line and no meaningful match. Results explain each case.
8. Inspect a related line, open it in Builder/Trainer deliberately, and return to the same played game and move.
9. Enter Solitaire chess from a configured analysis layout. Answers remain concealed; leaving restores the previous layout without changing its defaults.
10. Verify a long annotated game and a large course at a normal and narrow desktop width. No clipped controls, unreadable text or forced page hopping to read related lines.

## 12. Existing implementation to assess after feature review

This is reuse evidence, not a requirement to preserve the existing page architecture.

- `GameDeviationService` currently picks a deepest matching chapter per repertoire and unions continuations at ties. General transposition tolerance is explicitly absent, apart from generated transposition markers. The proposed multi-chapter/line matching needs broader behavior.
- `RepertoireLinePanel` already supports per-repertoire verdicts and line reading on the board, but it is a separate tab and loads lines from the chosen report chapter. It does not fulfill the requested full related-chapter outline.
- `GameAnalysisChart` already accepts the current ply and emits a selected ply. Reuse or adapt its analysis data/navigation rather than introducing a separate graph state.
- `runAddToStudyFlow`, filtered-games-to-study creation, `StudyController`, and typed page handoffs provide useful integration points. Single-game grouping is currently especially tied to Solitaire completion; it needs a general first-class flow.
- Existing slice models support header, position and move-sequence conditions. Rebuild the controls if helpful while preserving their useful semantics.
- Existing rating data should be left intact even though rating controls and rating-based sorting are removed from the proposed page.

## Review decisions

Edit the requirements above freely. The main unresolved decisions are:

1. What content should appear by default before the user customizes anything?
2. Where does the graph belong: below the board or below the moves?
3. How should games and related repertoire lines be grouped within a study?
4. What is the clearest chapter/line outline and matching priority for your courses?
5. Which navigation controls need visible words rather than symbols?

No application code was changed for this document. No original PGNs, studies or user databases were modified. The fixture inspection did not start Stockfish.
