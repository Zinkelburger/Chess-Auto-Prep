/// Study mode — general chess study: annotated move trees with variations
/// and comments, multiple chapters per study file, engine analysis, and a
/// board editor for custom starting positions.
///
/// Assembly of existing parts: [StudyController] (state) + board +
/// [InteractivePgnEditor] (move tree view) + [InlineEngineBar] (engine).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../core/study_controller.dart';
import '../models/move_tree.dart' show TreePath;
import '../services/repertoire_service.dart';
import '../services/study_import/study_import_controller.dart';
import '../services/study_import/study_import_exception.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../utils/board_shape_comments.dart';
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/board_editor/board_editor_dialog.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/common/searchable_picker_dialog.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/interactive_pgn_editor.dart';
import '../widgets/study/chapter_manager_dialog.dart';
import '../widgets/study/study_chapter_sidebar.dart';
import '../widgets/study/import_from_url_dialog.dart';
import '../widgets/study/study_import_status_chip.dart';
import '../widgets/trainer_keyboard_scope.dart';
import '../widgets/training/move_input_widget.dart';

class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  late final StudyController _study;
  final FocusNode _focusNode = FocusNode();
  final GlobalKey<MoveInputWidgetState> _moveInputKey = GlobalKey();

  /// Inline study rename (click the name in the app bar).
  bool _editingName = false;
  final TextEditingController _nameEditController = TextEditingController();

  AppState? _appStateRef;

  /// Background collection downloads. App-wide, because a run outlives this
  /// screen — [_seenImportGeneration] is seeded so a run that finished before
  /// the screen existed is not re-announced.
  final StudyImportController _import = StudyImportController.instance;
  late int _seenImportGeneration;

  @override
  void initState() {
    super.initState();
    _study = context.read<StudyController>();
    _study.addListener(_onStudyChanged);
    _study.refreshStudyList();
    _seenImportGeneration = _import.resultGeneration;
    _import.addListener(_onImportResult);

    // "Edit study" hook (e.g. from the Repertoire Trainer): open the pending
    // file now and on later AppState notifications — the screen is cached in
    // main_screen's IndexedStack, so handoffs after first build arrive as
    // notifications, not a fresh initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      _appStateRef = appState;
      appState.addListener(_onAppStateChanged);
      _consumePendingStudyPath(appState);
    });
  }

  void _onAppStateChanged() {
    final appState = _appStateRef;
    if (appState == null || !mounted) return;
    if (appState.currentMode != AppMode.study) return;
    _consumePendingStudyPath(appState);
  }

  void _consumePendingStudyPath(AppState appState) {
    final handoff = appState.takeHandoff<EditStudy>();
    if (handoff == null) return;
    unawaited(_openFromHandoff(handoff));
  }

  Future<void> _openFromHandoff(EditStudy handoff) async {
    await _study.openStudy(handoff.studyPath);
    if (!mounted) return;
    final chapterIndex = handoff.chapterIndex;
    final chapterName = handoff.chapterName;
    if (chapterIndex != null && _study.doc.chapters.isNotEmpty) {
      // Browse↔Edit toggle: the producer showed this same file, index is
      // exact.
      _study.selectChapter(
        chapterIndex.clamp(0, _study.doc.chapters.length - 1),
      );
    } else if (chapterName != null) {
      // Last match: add-to-study appends, and names aren't unique.
      final index = _study.doc.chapters.lastIndexWhere(
        (c) => c.name == chapterName,
      );
      if (index >= 0) _study.selectChapter(index);
    }
    final sanLine = handoff.initialSanLine;
    if (sanLine != null && sanLine.isNotEmpty) {
      _study.jumpToSanLine(sanLine);
    }
  }

  @override
  void dispose() {
    _appStateRef?.removeListener(_onAppStateChanged);
    _import.removeListener(_onImportResult);
    _study.removeListener(_onStudyChanged);
    _focusNode.dispose();
    _nameEditController.dispose();
    super.dispose();
  }

  void _onStudyChanged() {
    if (mounted) setState(() {});
  }

  // ── Keyboard ─────────────────────────────────────────────────────────

  /// Study-mode shortcuts, dispatched through [handleKeyBindings] (never
  /// while typing).
  List<KeyBinding> get _keyBindings => [
    ...KeyBinding.forShortcut(
      AppShortcut.backOneMove,
      'Back one move',
      _study.goBack,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.forwardOneMove,
      'Forward one move',
      _study.goForward,
      repeats: true,
    ),
    // Home/End jump to the line's ends (as in the PGN viewer); P/S (and ↓/↑)
    // step the queue in front of you, which here is the chapter list.
    ...KeyBinding.forShortcut(
      AppShortcut.goToStart,
      'Go to start',
      _study.goToStart,
    ),
    ...KeyBinding.forShortcut(AppShortcut.goToEnd, 'Go to end', _study.goToEnd),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleEngine,
      'Toggle engine',
      InlineEngineBar.toggleEngine,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.flipBoard,
      'Flip board',
      _study.toggleFlipped,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.browseInViewer,
      'Browse in PGN viewer',
      _browseInViewer,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.nextItem,
      'Next chapter',
      () => _study.selectChapter(_study.chapterIndex + 1),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.previousItem,
      'Previous chapter',
      () => _study.selectChapter(_study.chapterIndex - 1),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.focusMoveInput,
      'Focus move input',
      () => _moveInputKey.currentState?.focus(),
    ),
    // Jump into the annotation panel's comment field for the current move.
    ...KeyBinding.forShortcutIf(
      AppShortcut.commentMove,
      'Comment current move',
      PgnAnnotationPanel.focusActive,
    ),
  ];

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) =>
      handleKeyBindings(_keyBindings, event, node: node);

  /// Click on an engine-line move: play the PV into the chapter up to and
  /// including the clicked move (existing moves are followed, new ones
  /// become variations — same behavior as the PGN viewer).
  void _addEngineLine(List<String> sanMoves, int clickedIndex) {
    for (var i = 0; i <= clickedIndex && i < sanMoves.length; i++) {
      if (!_study.playSan(sanMoves[i])) break;
    }
  }

  // ── Study / chapter management ───────────────────────────────────────

  Future<String?> _promptName(String title, {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    final safe = result
        ?.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    if (safe == null) return null;
    if (safe.isEmpty) {
      if (mounted) showAppSnackBar(context, 'Invalid name.', isError: true);
      return null;
    }
    return safe;
  }

  Future<void> _newStudy() async {
    final name = await _promptName('New study');
    if (name == null) return;
    try {
      await _study.newStudy(name);
    } on ArgumentError catch (e) {
      if (mounted) showAppSnackBar(context, e.message as String, isError: true);
    }
  }

  void _startNameEdit() {
    _nameEditController.text = _study.doc.name;
    _nameEditController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameEditController.text.length,
    );
    setState(() => _editingName = true);
  }

  Future<void> _commitNameEdit() async {
    if (!_editingName) return;
    setState(() => _editingName = false);
    final safe = _nameEditController.text
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    if (safe.isEmpty || safe == _study.doc.name) return;
    try {
      await _study.renameStudy(safe);
    } on ArgumentError catch (e) {
      if (mounted) showAppSnackBar(context, e.message as String, isError: true);
    }
  }

  // ── Import from URL ──────────────────────────────────────────────────

  /// Download a Lichess study or a chessgames.com collection.
  ///
  /// The dialog resolves the source and hands back a plan: Lichess arrives
  /// whole and is filed immediately, a collection is a paced multi-minute
  /// download and is handed to [StudyImportController] to run in the
  /// background (results arrive via [_onImportResult]).
  Future<void> _importFromUrl() async {
    final plan = await ImportFromUrlDialog.show(
      context,
      canAppend: _study.doc.filePath != null,
    );
    if (plan == null || !mounted) return;

    switch (plan) {
      case LichessStudyPlan():
        await _applyLichessPlan(plan);
      case CollectionPlan():
        _startCollectionDownload(plan);
    }
  }

  Future<void> _applyLichessPlan(LichessStudyPlan plan) async {
    if (plan.appendToCurrent) {
      final added = await _study.importChapters(plan.pgn);
      if (!mounted) return;
      showAppSnackBar(
        context,
        added == 0
            ? 'Nothing to import from that study.'
            : 'Added $added chapter${added == 1 ? '' : 's'} '
                  'from "${plan.name}".',
        isError: added == 0,
      );
      return;
    }

    await _study.createStudyFromPgn(plan.name, plan.pgn);
    if (!mounted) return;
    final chapters = _study.doc.chapters.length;
    showAppSnackBar(
      context,
      'Imported "${_study.doc.name}" — $chapters '
      'chapter${chapters == 1 ? '' : 's'}.',
    );
  }

  void _startCollectionDownload(CollectionPlan plan) {
    final minutes = (plan.gameIds.length * plan.delay.inSeconds / 60)
        .ceil()
        .clamp(1, 9999);
    try {
      // Deliberately not awaited: the run outlives this screen, and progress
      // comes back through the status chip and [_onImportResult].
      unawaited(
        _import.startCollectionDownload(
          gameIds: plan.gameIds,
          studyName: plan.studyName,
          delay: plan.delay,
        ),
      );
    } on StudyImportException catch (e) {
      showAppSnackBar(context, e.message, isError: true);
      return;
    }
    showAppSnackBar(
      context,
      'Downloading ${plan.gameIds.length} games (~$minutes min). '
      'chessgames.com is slow on purpose — keep working, it runs in the '
      'background.',
    );
  }

  /// One SnackBar per finished collection download, whenever Study mode is on
  /// screen to show it. The job entry in the jobs panel is the durable record.
  void _onImportResult() {
    if (!mounted) return;
    final result = _import.lastResult;
    if (result == null || _import.resultGeneration == _seenImportGeneration) {
      return;
    }
    _seenImportGeneration = _import.resultGeneration;

    final error = result.error;
    final message =
        error ??
        (result.cancelled
            ? 'Stopped after ${result.chapters} of '
                  '${result.chapters + result.failed} games — saved as '
                  '"${result.studyName}".'
            : 'Imported ${result.chapters} games into "${result.studyName}"'
                  '${result.failed > 0 ? ' (${result.failed} unavailable)' : ''}.');

    final path = result.studyPath;
    showAppSnackBar(
      context,
      message,
      isError: error != null,
      actionLabel: result.wroteAnything ? 'Open' : null,
      onAction: result.wroteAnything ? () => _study.openStudy(path!) : null,
    );
  }

  /// Paste-in PGN import: every game becomes a chapter appended to the study.
  Future<void> _importPgn() async {
    final controller = TextEditingController();
    final pgn = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import PGN'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 6,
            maxLines: 14,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText:
                  'Paste one or more games in PGN…\n\n'
                  'Each game becomes a chapter.',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pgn == null || pgn.trim().isEmpty) return;
    final added = await _study.importChapters(pgn);
    if (!mounted) return;
    showAppSnackBar(
      context,
      added == 0
          ? 'No games found in that PGN.'
          : 'Imported $added chapter${added == 1 ? '' : 's'}.',
      isError: added == 0,
    );
  }

  /// Copy the whole study (all chapters) as PGN to the clipboard.
  Future<void> _exportPgn() async {
    await _study.flushSave();
    await Clipboard.setData(ClipboardData(text: _study.doc.toPgn()));
    if (mounted) showAppSnackBar(context, 'Study PGN copied to clipboard.');
  }

  Future<void> _deleteCurrentStudy() async {
    final path = _study.doc.filePath;
    if (path == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete study "${_study.doc.name}"?'),
        content: const Text('The PGN file will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.dangerSurface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _study.deleteStudy(path);
  }

  Future<void> _addChapter({bool fromPosition = false}) async {
    String? startingFen;
    if (fromPosition) {
      final position = await BoardEditorDialog.show(
        context,
        actionLabel: 'Start chapter here',
      );
      if (position == null) return;
      startingFen = position.fen;
    }
    if (!mounted) return;
    final name = await _promptName('New chapter');
    if (name == null) return;
    _study.addChapter(name, startingFen: startingFen);
  }

  /// Open the board editor to set/replace the current chapter's starting
  /// position. Existing moves are rooted in the old position, so replacing
  /// it clears them (after confirmation).
  Future<void> _editChapterPosition() async {
    if (_study.chapterHasMoves) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace starting position?'),
          content: Text(
            'Chapter "${_study.chapter.name}" already has moves; setting a '
            'new starting position will clear them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    final position = await BoardEditorDialog.show(
      context,
      initialFen: _study.currentPosition.fen,
      actionLabel: 'Set chapter position',
    );
    if (position == null) return;
    _study.setChapterStartingPosition(position.fen);
  }

  /// Train this study (or just the current chapter) in the Repertoire
  /// Trainer's tactics mode: each chapter is one puzzle — starting FEN,
  /// solution mainline, comments shown as annotations.
  Future<void> _train({required bool wholeStudy}) async {
    final path = _study.doc.filePath;
    if (path == null) {
      showAppSnackBar(
        context,
        'Save the study first (create it by name).',
        isError: true,
      );
      return;
    }
    final hasMoves = wholeStudy
        ? _study.doc.chapters.any((c) => c.tree.roots.isNotEmpty)
        : _study.chapterHasMoves;
    if (!hasMoves) {
      showAppSnackBar(
        context,
        wholeStudy
            ? 'No chapters with moves to train yet.'
            : 'This chapter has no moves to train yet.',
        isError: true,
      );
      return;
    }
    // Focus one chapter by the *same* line id the trainer will derive when it
    // re-parses the saved file. Deriving it from this chapter's PGN (header
    // preferred, stable fallback) rather than assuming the stable fallback
    // keeps "Train this chapter" correct even for studies imported with a
    // LineID/Id/Guid header (Chessable/ChessBase exports).
    String? lineId;
    if (!wholeStudy) {
      final service = RepertoireService();
      lineId =
          service.lineIdForGamePgn(
            _study.chapter.toPgn(),
            _study.chapterIndex,
          ) ??
          service.generateLineId(
            _study.tree.sanSequenceAt(
              _study.tree.mainlineEndFrom(TreePath.empty),
            ),
            _study.chapterIndex,
          );
    }
    await _study.flushSave();
    if (!mounted) return;
    context.read<AppState>().switchToStudyTraining(path: path, lineId: lineId);
  }

  /// The Edit↔Browse toggle: reopen this study as a game collection in the
  /// PGN viewer, parked on the same chapter. The viewer's own toggle comes
  /// straight back here.
  Future<void> _browseInViewer() async {
    final path = _study.doc.filePath;
    if (path == null) {
      showAppSnackBar(
        context,
        'Save the study first (create it by name).',
        isError: true,
      );
      return;
    }
    await _study.flushSave();
    if (!mounted) return;
    context.read<AppState>().switchToPgnViewer(
      path: path,
      gameIndex: _study.chapterIndex,
      historyLabel: 'PGN: ${_study.doc.name}',
    );
  }

  Future<void> _manageChapters() async {
    await showChapterManagerDialog(
      context,
      study: _study,
      promptName: _promptName,
    );
    if (mounted) setState(() {});
  }

  Future<void> _renameChapterAt(int index) async {
    final name = await _promptName(
      'Rename chapter',
      initial: _study.doc.chapters[index].name,
    );
    if (name == null) return;
    _study.renameChapter(index, name);
  }

  /// Gear action on a sidebar row: the board-editor flow edits the *current*
  /// chapter, so switch to that chapter first.
  Future<void> _setStartingPositionAt(int index) async {
    _study.selectChapter(index);
    await _editChapterPosition();
  }

  Future<void> _deleteChapterAt(int index) async {
    if (_study.doc.chapters.length <= 1) {
      showAppSnackBar(
        context,
        'A study needs at least one chapter.',
        isError: true,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete chapter "${_study.doc.chapters[index].name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.dangerSurface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _study.deleteChapter(index);
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: AppBarTitleWithTrail(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Study'),
              const SizedBox(width: 16),
              Flexible(child: _buildStudyPicker()),
            ],
          ),
        ),
        actions: [
          // Only visible while a collection download is running.
          const StudyImportStatusChip(),
          // Chapter-scoped actions (starting position, rename, delete, order)
          // all live on the chapter bar in the side pane; the app bar keeps
          // only what applies to the study or the board as a whole.
          PopupMenuButton<String>(
            icon: const Icon(Icons.school_outlined, size: 20),
            tooltip: 'Train in Repertoire Trainer',
            onSelected: (action) => _train(wholeStudy: action == 'study'),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'chapter',
                child: Text('Train this chapter'),
              ),
              PopupMenuItem(value: 'study', child: Text('Train whole study')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.menu_book, size: 20),
            tooltip: 'Browse in PGN viewer (A)',
            onPressed: _study.doc.filePath == null ? null : _browseInViewer,
          ),
          IconButton(
            icon: const Icon(Icons.swap_vert, size: 20),
            tooltip: 'Flip board',
            onPressed: _study.toggleFlipped,
          ),
          const AppSettingsButton(),
          const AppModeMenuButton(),
        ],
      ),
      body: TrainerKeyboardScope(
        holdsFocus: true,
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < kCompactBreakpoint;
            final board = _buildBoardPane();
            final side = _buildSidePane(compact: compact);
            // Wide: Lichess study layout — chapters | board | moves. Compact
            // keeps the stacked two-pane layout with the chapter bar in the
            // side pane.
            return compact
                ? Column(
                    children: [
                      Expanded(flex: 5, child: board),
                      const Divider(height: 1),
                      Expanded(flex: 4, child: side),
                    ],
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: 240,
                        child: StudyChapterSidebar(
                          study: _study,
                          onAddChapter: _addChapter,
                          onAddChapterFromPosition: () =>
                              _addChapter(fromPosition: true),
                          onRenameChapter: _renameChapterAt,
                          onSetStartingPosition: _setStartingPositionAt,
                          onDeleteChapter: _deleteChapterAt,
                        ),
                      ),
                      Container(width: 1, color: AppColors.outline),
                      Expanded(flex: 5, child: board),
                      Container(width: 1, color: AppColors.outline),
                      Expanded(flex: 4, child: side),
                    ],
                  );
          },
        ),
      ),
    );
  }

  /// Both the study and the chapter chooser go through a searchable dialog
  /// rather than a dropdown: neither a `DropdownButton` nor a
  /// `PopupMenuButton` can host a text field, and a course-sized study is a
  /// scroll hunt without one.
  Future<void> _pickStudy() async {
    final current = _study.doc;
    final picked = await showSearchablePicker<String>(
      context: context,
      title: 'Switch study',
      searchHint: 'Search studies',
      selected: current.filePath,
      items: [
        for (final study in _study.availableStudies)
          PickerItem(
            value: study.filePath,
            label: study.name,
            subtitle:
                '${study.gameCount} chapter'
                '${study.gameCount == 1 ? '' : 's'}',
            icon: Icons.menu_book_outlined,
          ),
      ],
      emptyMessage: 'No studies yet — import or create one.',
    );
    if (picked != null && picked != current.filePath) {
      await _study.openStudy(picked);
    }
  }

  Future<void> _pickChapter() async {
    final picked = await showSearchablePicker<int>(
      context: context,
      title: 'Go to chapter',
      searchHint: 'Search chapters',
      selected: _study.chapterIndex,
      items: [
        for (final (i, chapter) in _study.doc.chapters.indexed)
          PickerItem(
            value: i,
            label: chapter.name,
            subtitle: 'Chapter ${i + 1}',
            icon: Icons.bookmark_outline,
          ),
      ],
      emptyMessage: 'This study has no chapters yet.',
    );
    if (picked != null) _study.selectChapter(picked);
  }

  Widget _buildStudyPicker() {
    final theme = Theme.of(context);
    final current = _study.doc;
    // A file opened from outside the studies directory ("Edit set in
    // Study") is not in availableStudies and keeps its own name.
    final knownPaths = _study.availableStudies.map((s) => s.filePath).toSet();
    final isExternal =
        current.filePath != null && !knownPaths.contains(current.filePath);
    final canRename = current.filePath != null && !isExternal;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_editingName)
          SizedBox(
            width: 220,
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  setState(() => _editingName = false); // cancel
                  _focusNode.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              onFocusChange: (focused) {
                if (!focused) _commitNameEdit();
              },
              child: TextField(
                controller: _nameEditController,
                autofocus: true,
                style: theme.textTheme.bodyMedium,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                onSubmitted: (_) => _commitNameEdit(),
              ),
            ),
          )
        else
          Tooltip(
            message: canRename ? 'Click to rename' : '',
            child: InkWell(
              onTap: canRename ? _startNameEdit : null,
              borderRadius: BorderRadius.circular(4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Text(
                    isExternal ? '${current.name} (set)' : current.name,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.arrow_drop_down, size: 22),
          tooltip: 'Switch study',
          visualDensity: VisualDensity.compact,
          onPressed: _pickStudy,
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          tooltip: 'New study',
          onPressed: _newStudy,
        ),
        // Shown even with no study open — importing is how the first study
        // gets created; only the actions that need a file are withheld.
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18),
          tooltip: 'Manage studies',
          onSelected: (action) {
            switch (action) {
              case 'importUrl':
                _importFromUrl();
              case 'import':
                _importPgn();
              case 'export':
                _exportPgn();
              case 'delete':
                _deleteCurrentStudy();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'importUrl',
              child: Text('Import from URL…'),
            ),
            const PopupMenuItem(value: 'import', child: Text('Import PGN…')),
            if (current.filePath != null) ...[
              const PopupMenuItem(
                value: 'export',
                child: Text('Copy study PGN'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete study…'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Right-drag on the board: draw an arrow (or a circle, when the drag starts
  /// and ends on one square) into the current move's comment.
  ///
  /// Modifiers pick the colour the way Lichess does, and re-drawing the same
  /// shape erases it. Shapes are stored as `[%cal]`/`[%csl]` tokens, so they
  /// export with the PGN instead of living only in this app.
  void _onShapeDrawn(String orig, String? dest) {
    if (!_study.cursorHasNode) {
      showAppSnackBar(
        context,
        'Play a move first — arrows attach to a move, not the start position.',
      );
      return;
    }
    final keys = HardwareKeyboard.instance;
    final brush = keys.isShiftPressed
        ? AnnotationBrush.red
        : keys.isAltPressed
        ? AnnotationBrush.blue
        : keys.isControlPressed
        ? AnnotationBrush.yellow
        : AnnotationBrush.green;

    final comment = _study.cursorComment;
    final next = toggleBoardShape(
      parseBoardShapes(comment),
      BoardAnnotation(orig: orig, dest: dest, brush: brush),
    );
    _study.setComment(_study.path, writeBoardShapes(comment, next));
  }

  Widget _buildBoardPane() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  position: _study.currentPosition,
                  flipped: _study.flipped,
                  onMove: (move) => _study.playSan(move.san),
                  annotations: parseBoardShapes(_study.cursorComment),
                  onShapeDrawn: _onShapeDrawn,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: MoveInputWidget(
              key: _moveInputKey,
              position: _study.currentPosition,
              onMove: (move) => _study.playSan(move.san),
              // Non-move keys (↑/↓, empty-field ←/→, …) keep working as
              // shortcuts while a move is being typed; move characters
              // ("e4", "Nf3") always type normally.
              onNavigationKey: (event) =>
                  handleMoveInputNavigationKey(_keyBindings, event),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidePane({required bool compact}) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // Engine on top of the side pane — same spot as the PGN viewer.
        InlineEngineBar(
          fen: _study.currentPosition.fen,
          previewFlipped: _study.flipped,
          onLineMoveTapped: _addEngineLine,
        ),
        const Divider(height: 1),
        // Compact-only chapter bar; on wide layouts the sidebar owns
        // chapter switching and management.
        if (compact) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: _pickChapter,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _study.doc.chapters.isEmpty
                                  ? 'No chapters'
                                  : _study
                                        .doc
                                        .chapters[_study.chapterIndex]
                                        .name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'New chapter',
                  visualDensity: VisualDensity.compact,
                  onPressed: _addChapter,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  tooltip: 'Chapter actions',
                  onSelected: (action) {
                    switch (action) {
                      case 'manage':
                        _manageChapters();
                      case 'add_from_position':
                        _addChapter(fromPosition: true);
                      case 'set_position':
                        _editChapterPosition();
                      case 'rename':
                        _renameChapterAt(_study.chapterIndex);
                      case 'delete':
                        _deleteChapterAt(_study.chapterIndex);
                    }
                  },
                  // "Train this chapter" used to sit here as well as in the app
                  // bar's train menu; one home each is enough.
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'manage',
                      child: Text('Manage & reorder chapters…'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'add_from_position',
                      child: Text('New chapter from position…'),
                    ),
                    PopupMenuItem(
                      value: 'set_position',
                      child: Text('Set starting position…'),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text('Rename chapter…'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete chapter…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 8),
        ] else
          const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: InteractivePgnEditor(
              tree: _study.tree,
              currentPath: _study.path,
              currentRepertoireName: _study.chapter.name,
              showAnnotationPanel: true,
              onJump: _study.jump,
              onCommentChanged: _study.setComment,
              onToggleNag: _study.toggleNag,
              onDelete: _study.deleteAt,
              onPromote: _study.promote,
              onMakeMainLine: _study.makeMainLine,
              onCopyToClipboard: (text, message) {
                Clipboard.setData(ClipboardData(text: text));
                showAppSnackBar(context, message);
              },
            ),
          ),
        ),
      ],
    );
  }
}
