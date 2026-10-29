import 'dart:async';

import 'package:flutter/widgets.dart';

import '../features/books/books_screen.dart' show newBook;
import '../features/pgn_viewer/export_dialog.dart';
import '../features/settings/setting_rows.dart';
import '../features/settings/settings_dialog.dart';
import '../features/tactics/my_games_block.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../ui/choice_dialog.dart';
import '../workspace/document/copy_name_dialog.dart';
import '../workspace/document/document_actions.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'board_doors.dart';
import 'document_views.dart';
import 'full_screen.dart';
import 'layout_memory.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'save_held.dart' as held;
import 'search_door.dart';
import 'window_columns.dart';
import 'workspace_requests.dart';

/// What the Actions menu offers in the mode on screen, the same actions
/// typed for in the palette, and the dialogs they open: the settings, a
/// copy of the file, the held moves saved, the PGN exported.
final class WindowActions {
  WindowActions({
    required this.requests,
    required this.workspace,
    required this.documents,
    required this.training,
    required this.labs,
    required this.columns,
    required this.layoutMemory,
    required this.doors,
    required this.search,
    required this.fullScreen,
    required this.editing,
    required this.view,
    required this.inspecting,
    required this.settingRows,
    required this.settingsAlso,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;
  final DocumentModes documents;
  final TrainingModes training;
  final LabModes labs;
  final WindowColumns columns;
  final LayoutMemory layoutMemory;
  final BoardDoors doors;
  final SearchDoor search;
  final FullScreen fullScreen;
  final ValueNotifier<bool> editing;

  /// The mode on screen, and whether its Analysis tab inspects a board of
  /// its own.
  final ModeView Function() view;
  final bool Function() inspecting;

  /// The settings page's rows, as the app wires them, and the one owner
  /// besides the store they are built from: the Lichess account.
  final List<SettingGroup> Function() settingRows;
  final Listenable settingsAlso;

  ModeView get _view => view();

  Workspace get _boardWorkspace =>
      inspecting() ? workspace.inspecting : workspace;

  /// Everything the Actions menu offers now, in the mode on screen.
  List<AppAction> entries(BuildContext context) => [
    ..._modeActions(context),
    AppAction('Reset workspace layout', _resetLayout, group: 'Layout'),
    AppAction(
      'Widen board',
      () => _view.layout.resizeBoard(_view.layout.boardFraction + 0.05),
      group: 'Layout',
    ),
    AppAction(
      'Widen reading area',
      () => _view.layout.resizeBoard(_view.layout.boardFraction - 0.05),
      group: 'Layout',
    ),
    if (_view.layout.count > 1) ...[
      AppAction(
        'Give this pane more room',
        () => _view.layout.resizeActive(0.05),
        group: 'Layout',
      ),
      AppAction(
        'Give this pane less room',
        () => _view.layout.resizeActive(-0.05),
        group: 'Layout',
      ),
    ],
    if (_view is! ViewerView)
      AppAction(
        columns.positionsUp ? 'Back to the list' : 'Positions',
        columns.togglePositions,
        shortcut: AppKey.positions.label,
        group: 'Panels',
      ),
    if (_view is! ViewerView)
      AppAction(
        fullScreen.on ? 'Leave full screen' : 'Full screen',
        fullScreen.toggle,
        shortcut: AppKey.fullScreen.label,
        group: 'Window',
      ),
  ];

  void _resetLayout() {
    layoutMemory.reset();
    columns.reset();
  }

  List<AppAction> _modeActions(BuildContext context) => [
    if (!inspecting()) ..._view.layout.actions,
    ..._documentModeActions(context),
  ];

  List<AppAction> _documentModeActions(BuildContext context) => inspecting()
      ? [
          ...documentActions(
            session: _boardWorkspace.session,
            analysis: _boardWorkspace.analysis,
            editing: editing,
            onSaveCopy: () {},
          ),
          ...doors.entries(context),
          ...tabActions(_view.tabs),
        ]
      : _view.actions((
          editing: editing,
          board: () => boardActions(
            context,
            doors: doors,
            library: documents.library,
            onAnalyze: _view.offersNewAnalysis
                ? () => unawaited(analyze())
                : null,
          ),
          dialogs: (
            saveCopy: () => unawaited(_saveCopy(context)),
            saveHeld: () => saveHeld(context),
            exportPgn: () => unawaited(
              exportViewerPgn(context, documents.viewer, requests.say),
            ),
            search: () => unawaited(search.search(_view.layout)),
            accounts: () => unawaited(editAccounts(context, training.myGames)),
            newBook: () =>
                unawaited(newBook(context, workspace.books, say: requests.say)),
          ),
        ));

  /// The same actions, typed for: a searchable list that the enter key
  /// takes the one match of.
  Future<void> palette(BuildContext context) async {
    final actions = [
      for (final mode in Mode.values)
        if (mode != Mode.bughouse || labs.offered.value)
          AppAction('Go to ${mode.label}', () => requests.switchTo(mode)),
      for (final a in entries(context))
        if (a.run != null) a,
    ];
    final chosen = await showChoiceDialog<AppAction>(
      context,
      title: 'Actions',
      options: actions,
      label: (action) => action.labelWithKey,
      hint: 'Type an action',
      empty: 'Nothing to do yet',
    );
    chosen?.run?.call();
  }

  Future<void> settings(BuildContext context) => showSettingsDialog(
    context,
    store: workspace.settings,
    groups: settingRows,
    also: settingsAlso,
  );

  /// The settings page with only its Training rows: the Train tab's gear.
  Future<void> trainingSettings(BuildContext context) => showSettingsDialog(
    context,
    store: workspace.settings,
    groups: () => settingRows().where((g) => g.name == 'Training').toList(),
  );

  /// A board of its own in the Analysis tab, from the position on screen.
  Future<void> analyze() async {
    training.puzzles.inspectAlternative();
    documents.autoplay.stop();
    _view.tabs.add(WorkspaceTab.analysis.tab);
  }

  Future<void> _saveCopy(BuildContext context) async {
    final name = await showCopyNameDialog(context);
    if (name == null || !context.mounted) return;
    // A file this app may not write cannot have a copy beside it either.
    final result = await workspace.session.saveCopy(
      name,
      into: workspace.session.readOnly == null
          ? null
          : documents.viewer.collections,
    );
    if (!context.mounted) return;
    sayCopy(requests.say, result);
  }

  void saveHeld(BuildContext context) => unawaited(
    held.saveHeld(
      context,
      session: workspace.session,
      requests: requests,
      collections: documents.viewer.collections,
    ),
  );
}
