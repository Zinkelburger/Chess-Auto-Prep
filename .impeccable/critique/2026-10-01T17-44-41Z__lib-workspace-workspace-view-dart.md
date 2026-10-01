---
target: Repertoire builder workspace
total_score: 27
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/home/anbernal/.local/share/chess-prep/worktrees/impeccable-design-doc/lib/workspace/workspace_view.dart"
target_fingerprint: "sha256:55c54ffe685420c4f76e20709fd68b0dbb08cf2a074a9e47788d8c129ab2dfe8"
target_path: /home/anbernal/.local/share/chess-prep/worktrees/impeccable-design-doc/lib/workspace/workspace_view.dart
timestamp: 2026-10-01T17-44-41Z
slug: lib-workspace-workspace-view-dart
---
⚠️ DEGRADED: single-context (ran inside a worker fork that may not spawn sub-agents); detector ran but does not scan Dart/Flutter, so Assessment B is screenshots only.

Target: Repertoire builder workspace (lib/workspace/action_layout.dart startBuilding, search_pane.dart, explorer_pane.dart, workspace_view.dart), headless 1280x720, Sicilian chapter, depth-2 Expectimax.

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Status line is short now; clipped when the pane is narrow |
| 2 | Match System / Real World | 3 | Chess vocabulary throughout; "1 in N games" still abstract |
| 3 | User Control and Freedom | 3 | Panes split/move/close; no one-click way back to the default split |
| 4 | Consistency and Standards | 3 | Lichess conventions; three different tab strips stacked (document, pane, explorer sources) |
| 5 | Error Prevention | 3 | Settings validated inline |
| 6 | Recognition Rather Than Recall | 2 | Expectimax settings always visible but crowd the table; Engine column clipped off |
| 7 | Flexibility and Efficiency | 3 | Ctrl+G, typed moves, pane splits |
| 8 | Aesthetic and Minimalist Design | 2 | Chapter heading + form + status eat half the right column at 720px |
| 9 | Error Recovery | 3 | Save recovery inline |
| 10 | Help and Documentation | 2 | Tooltips only |
| **Total** | | **27/40** | Good |

Priority issues
- [P1] Expectimax pane overflows at 1280x720: "Resume expectimax" and ChessDB segment clipped, Engine column cut off, "Their reply" header wraps (shots: docs/design/critique-2026-10-01/expectimax.png, nolist.png). Fix: fold the settings form behind a one-line summary ("Maia 2200 · depth 2 · engine 14 ▸") with the button beside it, giving the table the height and width. /impeccable layout
- [P1] The chapter heading ("Main / White · 1 line") spans both columns and costs ~80px over every pane. Fix: move it into the document tab or a single 24px line. /impeccable distill
- [P2] Explorer source row clips (TWIC hidden) at ~300px. Fix: shorter source labels or a typeable source field at narrow widths. /impeccable adapt
- [P2] Moves pane is half height; long lines wrap into a short scroller. Lichess's answer: explorer as an overlay toggled from a book icon in the Moves pane, so Moves takes full height until the book is open. /impeccable layout
- [P3] Three stacked tab vocabularies (document tabs, pane tabs, explorer segmented sources) read alike. Fix: make pane tabs visually lighter than document tabs. /impeccable quieter
