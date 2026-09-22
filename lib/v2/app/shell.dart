import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../features/library/outline_panel.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/pgn_viewer/pgn_viewer_panel.dart';
import '../features/study/quiz_menu.dart';
import '../features/study/studies.dart';
import '../features/settings/setting_rows.dart';
import '../features/settings/settings_dialog.dart';
import '../features/study/study_panel.dart';
import '../storage/chapter_files.dart';
import '../storage/settings_store.dart';
import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/theme.dart';
import '../workspace/chapter_commands.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_actions.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import '../workspace/side_dialog.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/replies.dart';
import '../workspace/workspace_keys.dart';
import '../workspace/workspace_view.dart';
import 'exit_guard.dart';
import 'top_bar.dart';

/// The window: a top bar with the mode menu and the Actions menu, the
/// mode's list on the left and the workspace filling the rest. Opening a
/// chapter from a list into the workspace is the one cross-feature request,
/// and it is handled here.
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.library,
    required this.studies,
    required this.viewer,
    required this.outline,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.replies,
    required this.settings,
    required this.settingRows,
    required this.leaving,
  });

  final Library library;
  final Studies studies;
  final PgnViewer viewer;
  final ChapterOutline outline;
  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;
  final Replies replies;
  final SettingsStore settings;

  /// The settings page's rows, as the app wires them.
  final List<SettingGroup> Function() settingRows;

  /// Asked before another document takes the screen, so words the file
  /// never took are not carried off it without the user saying so.
  final ExitGuard leaving;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  String? _error;

  /// The name of the copy the last leave-question wrote, until the next
  /// thing the bar says has carried it.
  String? _copy;
  var _mode = Mode.repertoires;

  /// Whether the edit strip is open. The strip's own Done closes it.
  final _editing = ValueNotifier(false);

  /// The columns and their widths. The user drags the dividers; the list
  /// column goes when hidden and the outline column comes and goes with the
  /// chapter, and the widths of the others stay what the user made them.
  /// The areas are the same three objects for the life of the window: the
  /// split view keys each pane by its area, and a pane rebuilt from a new
  /// area loses what it had open.
  final _panes = MultiSplitViewController();
  // The list starts as narrow as it goes: the board is what the window is
  // for, and the divider is there for whoever wants more of the list.
  final _list = Area(data: _Pane.list, size: paneMinWidth, min: paneMinWidth);
  final _outline = Area(
    data: _Pane.outline,
    size: outlineColumnWidth,
    min: paneMinWidth,
  );
  final _workspace = Area(
    data: _Pane.workspace,
    flex: 1,
    min: boardPaneMinWidth,
  );
  bool _outlineShown = false;
  bool _listShown = true;

  @override
  void initState() {
    super.initState();
    _outlineShown = _wantsOutline;
    _arrange();
    widget.session.addListener(_followTheChapter);
  }

  @override
  void dispose() {
    widget.session.removeListener(_followTheChapter);
    _editing.dispose();
    _panes.dispose();
    super.dispose();
  }

  void _arrange() => _panes.areas = [
    if (_listShown) _list,
    if (_outlineShown) _outline,
    _workspace,
  ];

  /// The outline is a repertoire chapter's lines, so it is there only when
  /// a chapter that is a whole file is open. A study chapter is one game of
  /// its file, its chapters are already in its own left column, and the line
  /// operations do not mean the same thing there — so it has no outline,
  /// whichever mode the user switches to.
  bool get _wantsOutline =>
      widget.session.source != null && widget.session.game == null;

  /// Puts the outline column in or takes it out when the open chapter
  /// changes what is wanted. The other two panes are left alone, so the
  /// list keeps its width and whatever it has open.
  void _followTheChapter() {
    if (!mounted || _wantsOutline == _outlineShown) return;
    _outlineShown = _wantsOutline;
    _arrange();
  }

  void _toggleList() {
    if (!mounted) return;
    setState(() => _listShown = !_listShown);
    _arrange();
  }

  /// Switching mode swaps the left column and nothing else: the same board,
  /// the same document and the same draft stay where they are. A study
  /// chapter opened from the study list is the same session on one game of
  /// its file.
  void _switchTo(Mode mode) {
    if (!mounted || mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == Mode.study) unawaited(widget.studies.refresh());
  }

  /// The session opens the file; this only says what came of it, and
  /// answers whether the document is now on the board. An open a later
  /// click overtook has nothing to say, so it says nothing.
  ///
  /// Opening a document takes the saver off the one that is open, and a
  /// draft it never wrote goes with it, so the user is asked first — the
  /// same question the closing window asks. When they answered it by saving
  /// a copy, the bar above says where those words went.
  Future<bool> _open(ChapterRef ref, {int? game}) async {
    // Clicking the chapter that is already open is not leaving it.
    if (ref == widget.session.source && game == widget.session.game) {
      return true;
    }
    if (!await _leftTheDocument()) return false;
    final result = await widget.session.open(ref, game: game);
    if (!mounted) return false;
    switch (result) {
      case OpenOvertaken():
        return false;
      case DocumentOpened():
        _said(null);
        unawaited(_askTheSide());
        return true;
      case OpenFailed(:final reason):
        _said(reason);
        return false;
    }
  }

  /// A repertoire chapter whose file does not say which side it is for is
  /// asked about once, and the answer is written into the file, so the
  /// question never comes back. Dismissing it leaves the file as it was,
  /// read as White, and it is asked again the next time the chapter opens.
  Future<void> _askTheSide() async {
    final chapter = widget.session.chapter;
    if (chapter == null || chapter.game != null || chapter.sideStated) return;
    final source = widget.session.source;
    final side = await showSideDialog(context, chapter: chapter.name);
    if (!mounted || side == null || widget.session.source != source) return;
    setSide(widget.session, side);
  }

  /// A file from the viewer's recent list: brought inside Documents if it
  /// is not, opened on its first game, and remembered once it is on the
  /// board. The viewer is the mode that shows files, so it comes to the
  /// front whichever mode asked.
  Future<void> _openFile(ChapterRef ref) async {
    final inside = await widget.viewer.fileFor(ref.path);
    if (inside == null || !mounted) return;
    _switchTo(Mode.pgnViewer);
    if (await _open(inside, game: 0)) unawaited(widget.viewer.opened(inside));
  }

  /// The desktop's file dialog, then the same door as the recent list.
  Future<void> _browse() async {
    final ref = await widget.viewer.browse();
    if (ref == null || !mounted) return;
    _switchTo(Mode.pgnViewer);
    if (await _open(ref, game: 0)) unawaited(widget.viewer.opened(ref));
  }

  /// Takes the document off the board, with the same question about a
  /// draft the file never took as opening another one asks.
  Future<void> _closeFile() async {
    if (widget.session.source == null) return;
    if (!await _leftTheDocument()) return;
    widget.session.closed();
    widget.viewer.closed();
    _said(null);
  }

  /// Whether the workspace may leave what it has open. When the user
  /// answered by saving a copy, the bar says where those words went, so
  /// the copy's name is carried to the next thing said.
  Future<bool> _leftTheDocument() async {
    if (!await widget.leaving.mayLeaveDocument()) return false;
    if (!mounted) return false;
    _copy = widget.leaving.lastCopy;
    widget.leaving.lastCopy = null;
    return true;
  }

  void _said(String? error) {
    final copy = _copy;
    _copy = null;
    setState(
      () => _error = error ?? (copy == null ? null : 'Saved a copy as $copy'),
    );
  }

  Future<void> _saveCopy() async {
    final name = await showCopyNameDialog(
      context,
      widget.session.chapter?.name ?? 'Chapter',
    );
    if (name == null || !mounted) return;
    final result = await widget.session.saveCopy(name);
    if (!mounted) return;
    _said(switch (result) {
      CopySaved(:final name) => 'Saved a copy as $name',
      CopyNameTaken() => 'That name is taken. Nothing was replaced.',
      CopyFailed(:final detail) => 'Could not save a copy: $detail',
    });
  }

  /// Everything the Actions menu offers now: the mode's own doors first,
  /// then what can be done to the document, whichever mode opened it.
  List<AppAction> _actions() => [
    AppAction('Open PGN file…', () => unawaited(_browse()), shortcut: 'Ctrl+O'),
    AppAction(
      'Close file',
      widget.viewer.file == null ? null : () => unawaited(_closeFile()),
    ),
    ...documentActions(
      session: widget.session,
      saver: widget.saver,
      analysis: widget.analysis,
      editing: _editing,
      onSaveCopy: () => unawaited(_saveCopy()),
    ),
    AppAction(
      'Next gap',
      (widget.replies.walk?.gaps ?? const []).isEmpty
          ? null
          : widget.replies.nextGap,
      group: 'Repertoire',
    ),
    if (widget.session.chapter case final chapter? when chapter.game == null)
      AppAction(
        chapter.side == Side.white ? 'Play as Black' : 'Play as White',
        () => setSide(widget.session, chapter.side.opposite),
        group: 'Repertoire',
      ),
    // Not built yet: the expectimax search that writes proposed lines into
    // a draft chapter. The entry is here so the menu has its final shape.
    const AppAction('Fill gaps from here…', null, group: 'Repertoire'),
  ];

  /// The same actions, typed for: a searchable list that the enter key
  /// takes the one match of.
  Future<void> _palette() async {
    final actions = [
      for (final a in _actions())
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

  Future<void> _settings() => showSettingsDialog(
    context,
    store: widget.settings,
    groups: widget.settingRows,
  );

  Map<ShortcutActivator, VoidCallback> get _windowKeys => {
    const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
        unawaited(_settings()),
    const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
        unawaited(_settings()),
    const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggleList,
    const SingleActivator(LogicalKeyboardKey.keyB, meta: true): _toggleList,
    const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
        unawaited(_browse()),
    const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () =>
        unawaited(_browse()),
    const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
        unawaited(_palette()),
    const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
        unawaited(_palette()),
  };

  /// The mode's list, with the `«` that hides it in its top right corner:
  /// the pane's edge is where the toggle lives, whichever mode fills it.
  Widget _leftColumn() {
    final toggle = ListToggle(shown: true, onPressed: _toggleList);
    return switch (_mode) {
      Mode.repertoires => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => LibraryPanel(
          library: widget.library,
          selected: widget.session.source,
          onOpen: _open,
          trailing: toggle,
        ),
      ),
      Mode.study => StudyPanel(
        studies: widget.studies,
        session: widget.session,
        onOpen: (study, chapter) => unawaited(_open(study, game: chapter)),
        trailing: toggle,
      ),
      Mode.pgnViewer => PgnViewerPanel(
        viewer: widget.viewer,
        onOpen: (file) => unawaited(_openFile(file)),
        onBrowse: () => unawaited(_browse()),
        trailing: toggle,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([
              widget.session,
              widget.saver,
              widget.analysis,
              widget.replies,
              widget.viewer,
              _editing,
            ]),
            builder: (context, _) => TopBar(
              mode: _mode,
              onMode: _switchTo,
              onSettings: () => unawaited(_settings()),
              listShown: _listShown,
              onToggleList: _toggleList,
              actions: _actions(),
            ),
          ),
          const Divider(height: 1),
          if (_error case final error?) _ErrorBar(error),
          Expanded(
            child: WorkspaceKeys(
              session: widget.session,
              analysis: widget.analysis,
              editing: _editing,
              extra: _windowKeys,
              child: _columns(),
            ),
          ),
        ],
      ),
    );
  }

  /// The columns the mode puts side by side, under one set of keys: the
  /// mode's own list, the outline when a repertoire chapter is open, and the
  /// workspace filling the rest, with a divider to drag between each pair.
  Widget _columns() {
    return MultiSplitViewTheme(
      data: paneTheme(Theme.of(context).colorScheme),
      child: MultiSplitView(controller: _panes, builder: _pane),
    );
  }

  Widget _pane(BuildContext context, Area area) => switch (area.data) {
    _Pane.list => _leftColumn(),
    _Pane.outline => OutlinePanel(
      outline: widget.outline,
      library: widget.library,
      session: widget.session,
      onOpen: _open,
    ),
    _ => WorkspaceView(
      session: widget.session,
      saver: widget.saver,
      analysis: widget.analysis,
      replies: widget.replies,
      editing: _editing,
      settings: widget.settings,
      moveMenu: _mode == Mode.study
          ? (path) => quizMenuItems(widget.session, path)
          : null,
    ),
  };
}

/// The columns of the window, left to right.
enum _Pane { list, outline, workspace }

/// The modes `v2` has. Each one fills the left column; the workspace, the
/// document and the draft in it are the same whichever is showing.
enum Mode {
  repertoires('Repertoires'),
  pgnViewer('PGN Viewer'),
  study('Study');

  const Mode(this.label);

  final String label;
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.l,
        vertical: Space.s,
      ),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}
