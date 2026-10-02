---
target: Chess Auto Prep workspace and remaining UI UX gaps
total_score: 25
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/home/anbernal/.local/share/chess-prep/worktrees/ui-ux-review-report/lib/workspace/workspace_view.dart"
target_fingerprint: "sha256:297982ccb8d8a7f87ec75d75e94f602b30e999be2ee05653c55bdc906f5de6e5"
target_path: /home/anbernal/.local/share/chess-prep/worktrees/ui-ux-review-report/lib/workspace/workspace_view.dart
timestamp: 2026-10-02T03-10-00Z
slug: lib-workspace-workspace-view-dart
---
Method: dual-agent (A: /root/ui_design_review · B: /root/ui_evidence_scan)

# Chess Auto Prep: remaining UI and usability work

Reviewed local main at 85a3d6af on October 1, 2026 (US/Eastern), alongside Claude's October 1 handoffs and the active follow-up worktrees. This is a design and source review, not a completed live usability or accessibility test.

The app has a coherent visual identity: a calm, dark workspace with the board and notation at its center. Keep that direction. The next improvements should make actions predictable, interrupted work resumable, hidden tools discoverable, and failures recoverable.

## What Impeccable said, and what changed

The earlier builder-only report scored 27/40. It was explicitly a single-context review using 1280×720 screenshots; the detector did not establish Dart coverage. That number is not an app-wide certification.

| Earlier finding | Current state |
|---|---|
| Expectimax settings crowd out the result table | Settings moved behind a gear; narrow toolbar fitting remains in the active pane task. |
| Chapter heading consumes height above every tab | Heading moved into the Moves content across modes. |
| Moves is permanently squeezed above Explorer | Builder now starts with Moves beside Expectimax; the book starts closed and opens from its control. |
| Explorer source buttons clip | A typeable source field replaces the buttons when space is narrow. |
| Several similar tab layers compete | Partly improved by the viewer's book-like default. Pane discovery and layout recovery still need attention. |

Already delivered: the PGN Viewer opens as a reading surface, defaults its Explorer to This file, and offers player-side filtering; player and tactics panels are quieter; Players & prep uses dense rows and overflow menus; large-file parsing and filtering received performance work.

## What Claude's agents are currently doing

Status is a point-in-time observation, not a completion claim. At the inspected checkpoint, these follow-ups were not integrated into the reviewed main.

| Task branch | Observed work | What still needs acceptance checking |
|---|---|---|
| codex/builder-trainer-two-panes | Active edits for trainer short panes, narrow Expectimax, and draggable internal dividers. | 1280×720 with both lists, long notes, errors, training ratings, and larger text. Preserve dragged proportions. |
| codex/expectimax-reply-source-shown | Active edits add a quiet ~ fallback marker and source tooltip, with saved provenance. | Reopen/resume, old results without provenance, and a non-hover way to understand the marker. |
| codex/drop-stockfish-word | Committed at 9bc363c7 on its task branch. | Verify integration; retain engine names where they distinguish choices. |
| codex/mcp-expectimax-reply-cutoff | Committed at 4e8fbea5 with further test edits. | Backend alignment; this is not a UI redesign. |
| codex/fix-import-faults-flake | Investigation underway; no edits at inspection. | Reliability work; no demonstrated UI change yet. |

A separate release-robustness task is working on packaging. Do not duplicate these tasks.

## Five priorities beyond that work

### 1. [P1] Protect work across accidental actions and temporary detours

The plain Discard button directly calls discardHeld. That clears all held edits; DraftKeeper then deletes their recovery checkpoint. Provide an undoable discard, or confirm the destructive scope with the document name before losing that recovery path. This is specifically about all unsaved edits, not a confirmation for every ordinary edit.

Repertoire training has a related continuity gap: changing mode or closing Train calls leave(), disposes the lesson and clears its board. Completed ratings are not shown to be lost, but the current sitting and unrated progress end. Suspend the lesson and offer Resume when returning. Keep explicit Back to lines as the end-sitting action.

Evidence: lib/workspace/edit_strip.dart:218; lib/workspace/document_session.dart:753; lib/workspace/draft_keeper.dart:128; lib/app/shell.dart:807; lib/features/trainer/trainer.dart:417.

Acceptance: an accidental Discard is recoverable; visiting another mode and returning restores the current training position. Suggested pass: impeccable harden.

### 2. [P2] Make Tactics Play match the list the player sees

Text search computes a narrowed shown list, but Play uses the broader queue and its count. Searching for one opponent, or getting no matches, can still launch unrelated puzzles.

Use the visible searched results for Play and its count. If the broader queue is intentional, label its scope explicitly. The other puzzle filters already affect the session, so matching their behavior is easier to learn.

Evidence: lib/features/tactics/tactics_panel.dart:124; lib/features/tactics/puzzle_trainer.dart:146.

Acceptance: searching to three puzzles starts those three; zero matches cannot silently start the full queue. Suggested pass: impeccable harden.

### 3. [P2] Put a next action beside failures and blocked work

Player analysis can retain old progress text after a failure, show a raw exception, and require discovering Reload in Player actions. Replace this with a clear failed state and an adjacent Retry/Reload. Retain usable cached results where feasible.

Engine contention elsewhere says to wait for the current job without naming or opening it. Show which analysis is running and provide Show running analysis. Existing local progress/stop controls should remain; a large jobs dashboard is unnecessary.

Typed-move failure currently changes only the text and border color. Add a short stable-height explanation on submission, such as That move is not legal here, plus an accessible announcement.

Evidence: lib/features/players/player_analysis.dart:218; lib/features/players/analysis_panel.dart:432; lib/workspace/game_review.dart:152; lib/workspace/game_review_pane.dart:94; lib/workspace/move_field.dart:151.

Acceptance: a failed download is visibly failed, its retry is adjacent, a blocked engine action leads to its owner, and illegal notation has a textual reason. Suggested passes: impeccable clarify and harden.

### 4. [P1 for assistive-technology users] Make the chess workspace accessible beyond pointer input

The board wrapper and installed chessground source expose no accessible square/position interaction layer. Typed SAN/UCI entry does exist; the missing capability is understanding and exploring the position nonvisually.

Add a meaningful position/square representation, keyboard square navigation and promotion choices. Preserve typed entry. Restore visible focus on document-tab close controls; their state overlay is currently transparent even when focused. Give selected tabs appropriate semantics and provide keyboard-accessible split adjustment/reset.

Evidence: lib/workspace/board_view.dart:148; lib/ui/pane_tabs.dart:443 and :479; lib/workspace/workspace_view.dart:291. Native assistive-technology behavior still needs runtime validation.

Acceptance: complete one game-navigation and training flow with keyboard alone, inspect its semantic tree, and verify visible focus and readable larger text. Suggested passes: impeccable audit and harden, using Flutter-native checks rather than the web detector.

### 5. [P2] Make tools easier to find and layouts easier to recover

The mode selector contains 11–12 flat destinations. Preserve their established names, but group related preparation tasks and include mode changes in the existing searchable Actions palette.

The reading surface's + is labeled Open tab, yet it contains tools, editing/engine actions, and pane creation. Give the entry point a truthful accessible name and a lightweight discoverable label/help affordance. Keep the calm reading default; test whether a new chess-expert user can find Filter and Game review without instruction.

Finish the pane agent's resizing work with an explicit Restore default layout action, including board/card widths. Join all panes already exists, but it does not reset the outer board/card split. Reading position/filter/sort persistence already exists; open tools and pane arrangements are not stored per file or across relaunch. Remember deliberate arrangements, with an easy return to the default.

Evidence: lib/app/top_bar.dart:105; lib/app/shell.dart:562; lib/workspace/action_panes.dart:227 and :277; lib/workspace/workspace_view.dart:291; lib/app/mode_view.dart:75; lib/chess/pgn/reading_place.dart:16.

Acceptance: a first-time user finds the right mode/tool; an expert recovers a readable layout in one action and can reopen a file without rebuilding a chosen workspace. Suggested passes: impeccable shape and adapt.

## Provisional design-health score

These are reviewer judgments from source and limited visual evidence, not measured user-test results. The broader scope and newly identified issues make this unsuitable as a before/after comparison with the earlier builder-only 27/40.

| Heuristic | Score /4 | Main reason |
|---|---:|---|
| System status | 3 | Good local progress/save states; failed analysis can retain stale status. |
| Real-world language | 3 | Good chess vocabulary; technical errors remain. |
| Control and freedom | 2 | Useful undo/history, but discard and training interruption need recovery. |
| Consistency | 3 | Shared controls; search/action scope and lesson lifecycle diverge. |
| Error prevention | 2 | Many safeguards; all-edit discard is too easy. |
| Recognition over recall | 2 | Flat modes and hidden tools require learned knowledge. |
| Efficiency | 3 | Strong shortcuts; layout setup still adds friction. |
| Minimalist design | 3 | Coherent quiet hierarchy; narrow panes remain constrained. |
| Error recovery | 2 | Save recovery is good; analysis failures and job contention need direct actions. |
| Help | 2 | Shortcut reference/tooltips exist; task discovery is weaker. |
| **Total** | **25/40** | **Provisional; target the specific gaps rather than the score.** |

## Strengths, personas and lower-priority work

The shared board/notation workspace, consistent dark tokens, centralized shortcut table, and PGN reading default deserve preserving. Save failures already have Retry save; read-only/conflict cases have copy/reload paths. Do not replace these with generic warnings.

For an expert preparing before a round, interruption/resume and action scope are the biggest trust issues. For a first-time chess expert, mode boundaries and hidden tools create a learning burden. For keyboard and low-vision users, accessible position information, focus and readable narrow layouts are essential.

Cognitive load is concentrated in the flat mode menu, overloaded tool menus, and remembering how to recreate a useful layout. The emotional high point is uninterrupted work on familiar notation; the low points are losing a training moment or receiving an error with no obvious next action.

Lower-priority follow-ups: distinguish document tabs from pane tabs subtly, verify long names/notes and larger text throughout Players & prep, and measure installed release-build interaction performance before changing the development launcher. Earlier debug measurements do not prove a specific release speedup. Keep destructive player actions in menus unless observed frequent use warrants a different choice.

## Proposed order and scope choices

First finish and verify the existing pane/provenance agents. Then fix discard recovery, training resume, and Tactics scope. Follow with actionable failure states and keyboard/accessibility work; finish with mode/tool discovery and layout memory.

Two choices can scope implementation:
1. Start with protecting work and predictable actions, finding tools and restoring layouts, or keyboard/accessibility?
2. Implement the top three concrete behavior fixes first, or a coordinated pass across all five priorities?

This report changes no app behavior.
