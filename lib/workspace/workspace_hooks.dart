import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../storage/chapter_files.dart';
import '../ui/app_action.dart';
import 'board/board_claim.dart';
import 'document/game_ordering.dart';
import 'reading/move_tree_view.dart';
import 'book/repertoire_tree.dart' show TreePlace;
import 'workspace_tabs.dart';

/// What the window around the workspace adds to it: the mode's own tabs
/// and right-click menu, where a move goes when it is not the document's,
/// and the ways out of the card into another mode. The default is a plain
/// document: every move into it, nothing of a mode's own.
final class WorkspaceHooks {
  const WorkspaceHooks({
    this.header = true,
    this.builder = false,
    this.noteEditing = false,
    this.onAnnotate,
    this.editSwitch = false,
    this.studyTools = false,
    this.gameCounter = true,
    this.gameOrdering,
    this.moveMenu,
    this.tabBody,
    this.boardClaim,
    this.lesson,
    this.trainingTools = false,
    this.onStudyLesson,
    this.onBoardMove,
    this.onEngineMove,
    this.onExplorerGame,
    this.onExplorerLogin,
    this.onDownloadTwic,
    this.onOpenChapter,
    this.onShowPositions,
    this.onOpenPlace,
    this.onEditBooks,
    this.onSaveHeld,
    this.quietBoard = false,
    this.paneActions,
    this.explorerFileBar,
    this.underHeading,
  });

  /// Opens the edit strip on the move a right-click was on: `Comment this
  /// move`.
  final VoidCallback? onAnnotate;

  /// Whether the card has `Read | Edit` at its foot, the one control that
  /// turns editing on and off in the viewer and Study.
  final bool editSwitch;

  /// Whether editing offers the quiz markers a study's training reads.
  final bool studyTools;
  final bool trainingTools;
  final VoidCallback? onStudyLesson;

  /// Under the heading: what the mode has to say about the game before it
  /// is read, such as where it left the user's book.
  final Widget? underHeading;

  /// Whether the board has only what is in use under it, as a book has a
  /// diagram and nothing else: the engine's row while the engine is on, the
  /// move field while it is typed in, the move's note when there is one or
  /// while it is edited. The viewer's and Study's while reading.
  final bool quietBoard;

  /// Under the explorer's databases while `This file` is chosen: the
  /// mode's way of narrowing the file's games.
  final Widget? explorerFileBar;

  /// What the mode adds to every pane's `+` under its tabs.
  final List<AppAction> Function()? paneActions;

  /// What the edit strip's Save does with held edits, when not simply
  /// writing them to their file.
  final VoidCallback? onSaveHeld;

  /// Opens the chapter a move of the book was found in, where it leads.
  final ValueChanged<TreePlace>? onOpenPlace;

  /// Shows the Books mode, to edit the books.
  final VoidCallback? onEditBooks;

  /// Asked to open a game the explorer lists, which is the shell's
  /// business: another mode shows it.
  final void Function(ExplorerGame, ExplorerSource, int)? onExplorerGame;
  final Future<bool> Function(BuildContext)? onExplorerLogin;
  final Future<bool> Function(BuildContext)? onDownloadTwic;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  /// A position another owner is showing on the board instead of the
  /// document's, while it holds one: a lesson.
  final ValueListenable<BoardClaim?>? boardClaim;

  /// The lesson's hold on the board, while one runs: every tab but Train
  /// would read out the moves it asks for, so they wait until it ends.
  final ValueListenable<BoardClaim?>? lesson;

  /// Opens a chapter in the builder: the draft a search's lines went to.
  final ValueChanged<ChapterRef>? onOpenChapter;

  /// Shows the Positions in the list column: where a search's finds are.
  final VoidCallback? onShowPositions;

  /// Where a move made on the board goes when not into the document: a
  /// puzzle judges it. Null plays it into the document.
  final ValueChanged<String>? onBoardMove;

  /// Where the moves of a clicked engine line go when not into the
  /// document: the explorer Book's free board. Null plays them into it.
  final ValueChanged<String>? onEngineMove;

  /// Whether the moves are headed with the game's players and the board has
  /// the file's game counter under it. Tactics has neither: the puzzle says
  /// whose game it was and the list is how to get to another.
  final bool header;
  final bool builder;
  final bool noteEditing;
  final bool gameCounter;
  final GameOrdering? gameOrdering;

  /// The body of a tab the workspace does not draw itself — Train,
  /// Puzzle, Book — which the mode on screen or the shell supplies. A tab it
  /// answers null for is empty.
  final Widget? Function(BuildContext context, WorkspaceTab tab)? tabBody;
}
