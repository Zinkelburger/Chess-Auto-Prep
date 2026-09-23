import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/tactics_actions.dart';
import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import '../workspace/chapter_commands.dart';
import '../workspace/document_actions.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/gap_hunt.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// What the window's own dialogs do, which the shell runs: they need its
/// context. The Actions menu only points at them.
typedef ShellDialogs = ({
  VoidCallback saveCopy,
  VoidCallback fill,
  VoidCallback accounts,
});

/// What the Actions menu offers in each mode: the mode's own doors first,
/// then what can be done to the document, whichever mode opened it, then
/// the card's tabs.
final class ModeActions {
  ModeActions({
    required this.requests,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.gaps,
    required this.fill,
    required this.viewer,
    required this.trainer,
    required this.myGames,
  });

  final WorkspaceRequests requests;
  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;
  final GapHunt gaps;
  final FillGaps fill;
  final PgnViewer viewer;
  final PuzzleTrainer trainer;
  final MyGames myGames;

  /// The entries for the mode on screen now.
  List<AppAction> now({
    required PaneTabs<WorkspaceTab> tabs,
    required ValueNotifier<bool> editing,
    required ShellDialogs dialogs,
  }) => switch (requests.mode) {
    Mode.tactics => tacticsActions(
      trainer: trainer,
      games: myGames,
      session: session,
      analysis: analysis,
      tabs: tabs,
      onAccounts: dialogs.accounts,
    ),
    Mode.myGames => [
      ...myGamesActions(myGames, onAccounts: dialogs.accounts),
      ..._document(editing, dialogs),
      ...tabActions(tabs),
    ],
    Mode.repertoires || Mode.pgnViewer || Mode.study => [
      ..._files(),
      ..._document(editing, dialogs),
      ..._repertoire(dialogs),
      ...tabActions(tabs),
    ],
  };

  /// Opening a file, and pasting one in the builder or closing it
  /// elsewhere.
  List<AppAction> _files() => [
    AppAction(
      'Open PGN file…',
      () => unawaited(requests.openPgnFile()),
      shortcut: 'Ctrl+O',
    ),
    if (requests.mode == Mode.repertoires)
      AppAction(
        'Paste PGN',
        () => unawaited(requests.pasteRepertoire()),
        shortcut: 'Ctrl+V',
      )
    else
      AppAction(
        'Close file',
        viewer.file == null ? null : () => unawaited(requests.closeFile()),
      ),
  ];

  List<AppAction> _document(
    ValueNotifier<bool> editing,
    ShellDialogs dialogs,
  ) => documentActions(
    session: session,
    saver: saver,
    analysis: analysis,
    editing: editing,
    onSaveCopy: dialogs.saveCopy,
  );

  /// The chapter as a repertoire: its gaps, its side and the fill.
  List<AppAction> _repertoire(ShellDialogs dialogs) => [
    AppAction(
      'Next gap',
      (gaps.walk?.gaps ?? const []).isEmpty ? null : gaps.nextGap,
      group: 'Repertoire',
    ),
    if (session.chapter case final chapter? when chapter.game == null)
      AppAction(
        chapter.side == Side.white ? 'Play as Black' : 'Play as White',
        () => setSide(session, chapter.side.opposite),
        group: 'Repertoire',
      ),
    AppAction(
      'Fill gaps from here…',
      fill.canStart ? dialogs.fill : null,
      group: 'Repertoire',
    ),
  ];
}
