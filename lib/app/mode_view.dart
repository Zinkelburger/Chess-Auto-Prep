import '../features/tournaments/tournament_run.dart';
import 'tournament_view.dart';

import 'package:flutter/material.dart';

import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import '../workspace/document_actions.dart';
import '../workspace/explorer.dart';
import '../workspace/game_ordering.dart';
import '../workspace/move_tree_view.dart' show MoveMenu;
import '../workspace/workspace.dart';
import '../workspace/action_layout.dart';
import '../workspace/workspace_tabs.dart';
import 'books_view.dart';
import 'bughouse_view.dart';
import 'document_views.dart';
import 'mode.dart';
import 'database_view.dart';
import '../features/databases/database_library.dart';
import 'player_wiring.dart';
import 'player_views.dart';
import 'training_views.dart';
import 'workspace_requests.dart';

/// What the window's own dialogs do, which the shell runs: they need its
/// context. The Actions menu only points at them.
typedef ShellDialogs = ({
  VoidCallback saveCopy,
  VoidCallback saveHeld,
  VoidCallback exportPgn,
  VoidCallback search,
  VoidCallback accounts,
  VoidCallback newBook,
});

/// What the Actions menu is built from besides the mode: whether the edit
/// strip is open, the analysis board's entries (built only when a mode
/// offers them, since they read the shell's context) and the dialogs.
typedef ModeMenu = ({
  ValueNotifier<bool> editing,
  List<AppAction> Function() board,
  ShellDialogs dialogs,
});

/// One mode as the window shows it: its list on the left, the tabs of its
/// reading card, its Actions menu, and what it adds to the workspace.
///
/// The shell asks the mode on screen rather than asking which mode is on
/// screen, so a mode's behaviour is in one class and a new mode is a new
/// subclass, not a new arm in every `switch` of the window. Each keeps its
/// own tabs for the life of the window, so what the user opened in one mode
/// is still open when they come back to it.
abstract base class ModeView {
  /// [explorer] is the mode's own, when its Explorer tab starts on a
  /// database of its own instead of the one the settings remember.
  ///
  /// [opensBeside] is for a mode whose first pane reads well at half the
  /// card's height: a tab picked while it is the only pane opens under it.
  ModeView(
    this.workspace,
    PaneTabs<WorkspaceTab> tabs, {
    Explorer? explorer,
    bool opensBeside = false,
    bool analysisInPanes = false,
  }) : _explorer = explorer,
       layout = ActionLayout(
         tabs,
         explorer ?? workspace.explorer,
         opensBeside: opensBeside,
         analysisInPanes: analysisInPanes,
       );

  final Workspace workspace;
  final Explorer? _explorer;

  /// The reading card's tabs in this mode: which are open and which is up.
  final ActionLayout layout;
  PaneTabs<WorkspaceTab> get tabs => layout.tabs;

  /// Brings [tab] up where it is open, else opens it as the layout opens a
  /// picked tab.
  void show(WorkspaceTab tab) => layout.reveal(tab);

  /// The left column, with [toggle] — the `«` that hides it — in its corner.
  Widget list(Widget toggle);

  /// Everything the Actions menu offers in this mode now.
  List<AppAction> actions(ModeMenu menu);

  /// What the entries' enabled states read, heard only while the menu is
  /// open.
  Listenable get changes;

  /// Whether the moves are headed with the game's players.
  bool get header => true;

  /// Whether the board has the file's game counter under it.
  bool get gameCounter => true;
  GameOrdering? get gameOrdering => null;

  /// Whether the Train tab offers to read a line in the builder: from
  /// anywhere but the builder itself.
  bool get offersBuilder => true;

  /// Whether the Actions menu offers the game on a new analysis tab. The
  /// viewer and Study do not: moves played while reading already stay off
  /// the file.
  bool get offersNewAnalysis => true;

  /// Whether the card has `Read | Edit` at its foot: the modes that read a
  /// game and write in it.
  bool get editSwitch => false;

  /// Whether the mode opens on Edit the first time it comes on screen;
  /// after that it keeps the side the user left it on.
  bool get startsEditing => false;

  /// Whether editing offers the quiz markers a study's training reads.
  bool get studyTools => false;

  /// What a right-click on a move offers.
  MoveMenu? get moveMenu => null;

  /// Under the heading: what the mode says about the game before it is
  /// read; null for nothing.
  Widget? get underHeading => null;

  /// Whether the board has only what is in use under it.
  bool get quietBoard => false;

  /// Under the explorer's databases while `This file` is chosen.
  Widget? get explorerFileBar => null;

  /// What every pane's `+` offers under its tabs: what the mode keeps out
  /// of sight until it is asked for.
  List<AppAction> paneActions(ValueNotifier<bool> editing) => const [];

  /// The body of a tab only this mode has, or null.
  Widget? tab(BuildContext context, WorkspaceTab tab) => null;

  /// ↓ (1) / ↑ (−1) when the mode walks a list of its own; answers whether
  /// it took the key.
  bool walk(int by) => false;

  /// Space, when no puzzle is up: the viewer plays the game forward.
  void space() {}

  /// Esc, once the workspace has nothing left to leave; whether the mode
  /// left anything. Tactics ends its sitting.
  bool leave() => false;

  /// Called when this mode comes on screen in place of another, whoever
  /// switched to it.
  void entered() {}

  /// Called when another mode comes on screen instead of this one.
  void left() {}

  /// The whole of the window under the top bar, for a mode that is a
  /// screen of its own rather than a list beside the workspace; null for
  /// the rest. The screen binds [windowKeys] beside its own.
  Widget? screen(Map<ShortcutActivator, VoidCallback> windowKeys) => null;

  void dispose() {
    layout.dispose();
    _explorer?.dispose();
  }

  /// What can be done to the document on the board, in every mode that
  /// shows one as a document.
  List<AppAction> documentEntries(ModeMenu menu) => documentActions(
    session: workspace.session,
    analysis: workspace.analysis,
    editing: menu.editing,
    onSaveCopy: menu.dialogs.saveCopy,
    onSaveHeld: menu.dialogs.saveHeld,
  );
}

/// The view of each mode, made once for the window.
Map<Mode, ModeView> modeViews({
  required Workspace workspace,
  required WorkspaceRequests requests,
  required DocumentModes documents,
  required TrainingModes training,
  required LabModes labs,
  required PlayerModes players,
  required DatabaseLibrary databases,
  required ValueNotifier<bool> editing,
  TournamentRun? tournaments,
  Future<bool> Function(BuildContext)? lichessLogin,
}) {
  final study = StudyView(
    workspace,
    requests,
    documents,
    editing,
    training.lines,
    lichessLogin: lichessLogin,
  );
  return {
    for (final mode in Mode.values)
      mode: switch (mode) {
        Mode.repertoires => RepertoiresView(workspace, requests, documents),
        Mode.trainer => TrainerView(workspace, requests, documents),
        Mode.books => BooksView(workspace, requests, documents),
        Mode.pgnViewer => ViewerView(workspace, requests, documents, editing),
        Mode.study => study,
        Mode.tactics => TacticsView(workspace, requests, training),
        Mode.myGames => MyGamesView(workspace, requests, training),
        Mode.bughouse => BughouseView(workspace, labs, requests.input),
        Mode.playerAnalysis => PlayerAnalysisView(workspace, requests, players),
        Mode.players => PlayersView(
          workspace,
          players,
          onTrainStudy: study.train,
        ),
        Mode.databases => DatabasesView(workspace, databases, requests),
        Mode.engineTournament => TournamentView(
          workspace,
          tournaments,
          requests,
        ),
      },
  };
}
