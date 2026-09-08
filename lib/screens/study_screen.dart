/// Study mode — composition root: [StudyController] plus board, PGN editor,
/// chapter sidebar, and engine. Layout widgets live under `widgets/study/`.
library;

import 'dart:async';
import 'dart:convert' show utf8;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../core/study_controller.dart';
import '../models/move_tree.dart' show TreePath;
import '../services/repertoire_line_ids.dart';
import '../services/repertoire_service.dart';
import '../services/storage/storage_factory.dart';
import '../services/study_import/study_import_controller.dart';
import '../services/study_import/study_import_exception.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/board_editor/board_editor_dialog.dart';
import '../widgets/common/confirm_dialog.dart';
import '../widgets/common/searchable_picker_dialog.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/study/chapter_manager_dialog.dart';
import '../widgets/study/edit_chapter_dialog.dart';
import '../widgets/study/import_from_url_dialog.dart';
import '../widgets/study/new_chapter_dialog.dart';
import '../widgets/study/study_board_pane.dart';
import '../widgets/study/study_chapter_actions.dart';
import '../widgets/study/study_chapter_sidebar.dart';
import '../widgets/study/study_import_status_chip.dart';
import '../widgets/study/study_name_dialog.dart';
import '../widgets/study/study_picker_bar.dart';
import '../widgets/study/study_side_pane.dart';
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

  AppState? _appStateRef;

  /// Background collection downloads. App-wide, because a run outlives this
  /// screen — [_seenImportGeneration] is seeded so a run that finished before
  /// the screen existed is not re-announced.
  final StudyImportController _import = StudyImportController.instance;
  late int _seenImportGeneration;
  String? _reportedSaveError;

  @override
  void initState() {
    super.initState();
    _study = context.read<StudyController>();
    _study.addListener(_onStudyChanged);
    unawaited(_study.refreshStudyList());
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
    super.dispose();
  }

  void _onStudyChanged() {
    if (!mounted) return;
    setState(() {});
    final error = _study.saveError;
    if (error == null) {
      _reportedSaveError = null;
    } else if (error != _reportedSaveError) {
      _reportedSaveError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showAppSnackBar(context, error, isError: true);
      });
    }
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
    // Home/End jump to the line's ends (as in the PGN viewer); ↑/↓
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

  Future<void> _newStudy() async {
    final name = await promptStudyName(context, title: 'New study');
    if (name == null) return;
    try {
      await _study.newStudy(name);
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

  /// Open a PGN file from disk: every game becomes a chapter appended to
  /// the study.  (Pasting PGN is the "New chapter" dialog's job.)
  Future<void> _importPgn() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Import PGN as chapters',
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
    );
    final path = file?.path;
    if (path == null) return;
    final pgn = await StorageFactory.instance.readFile(path) ?? '';
    if (!mounted) return;
    await _addChaptersFromPgn(pgn);
  }

  Future<void> _addChaptersFromPgn(
    String pgn, {
    String? name,
    Side? orientation,
  }) async {
    final added = await _study.importChapters(
      pgn,
      name: name,
      orientation: orientation,
    );
    if (!mounted) return;
    showAppSnackBar(
      context,
      added == 0
          ? 'No games found in that PGN.'
          : 'Added $added chapter${added == 1 ? '' : 's'}.',
      isError: added == 0,
    );
  }

  /// Copy the whole study (all chapters) as PGN to the clipboard.
  Future<void> _exportPgn() async {
    await _study.flushSave();
    await Clipboard.setData(ClipboardData(text: _study.doc.toPgn()));
    if (mounted) showAppSnackBar(context, 'Study PGN copied to clipboard.');
  }

  /// Write the study out as a PGN file of the user's choosing — the Lichess
  /// "Download" — leaving the study's own file where it is.
  Future<void> _saveStudyAs() async {
    await _study.flushSave();
    final outUri = await FilePicker.saveFile(
      dialogTitle: 'Save study PGN',
      fileName: '${_study.doc.name}.pgn',
      type: FileType.custom,
      allowedExtensions: ['pgn'],
      bytes: utf8.encode(_study.doc.toPgn()),
    );
    if (outUri == null || !mounted) return;
    showAppSnackBar(context, 'Saved ${p.basename(outUri.toFilePath())}.');
  }

  Future<void> _deleteCurrentStudy() async {
    final path = _study.doc.filePath;
    if (path == null) return;
    final confirmed = await confirmAction(
      context,
      title: 'Delete study "${_study.doc.name}"?',
      message: 'The PGN file will be moved to Chess Auto Prep recovery trash.',
      confirmLabel: 'Delete',
    );
    if (confirmed) await _study.deleteStudy(path);
  }

  /// The Lichess "New chapter" dialog: empty, from a position, or from
  /// pasted PGN (several games, several chapters).
  Future<void> _newChapter() async {
    final request = await showNewChapterDialog(
      context,
      defaultName: _study.nextChapterName(),
    );
    if (request == null || !mounted) return;
    switch (request) {
      case NewEmptyChapter():
        _study.addChapter(request.name, orientation: request.orientation);
      case NewChapterFromFen():
        _study.addChapter(
          request.name,
          startingFen: request.fen,
          orientation: request.orientation,
        );
      case NewChaptersFromPgn():
        await _addChaptersFromPgn(
          request.pgn,
          name: request.name,
          orientation: request.orientation,
        );
    }
  }

  /// Open the board editor to set/replace the current chapter's starting
  /// position. Existing moves are rooted in the old position, so replacing
  /// it clears them (after confirmation).
  Future<void> _editChapterPosition() async {
    if (_study.chapterHasMoves) {
      final confirmed = await confirmAction(
        context,
        title: 'Replace starting position?',
        message:
            'Chapter "${_study.chapter.name}" already has moves; setting a '
            'new starting position will clear them.',
        confirmLabel: 'Replace',
        destructive: false,
      );
      if (!confirmed) return;
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
            _study.chapterPgn(_study.chapterIndex),
            _study.chapterIndex,
          ) ??
          repertoireLineIds.stable(
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

  /// The chapter-row menu, shared by the sidebar, the compact chapter bar
  /// and the chapter manager.
  StudyChapterActions get _chapterActions => StudyChapterActions(
    onEdit: (i) => unawaited(_editChapterAt(i)),
    onSetStartingPosition: (i) => unawaited(_setStartingPositionAt(i)),
    onCopyPgn: (i) => unawaited(_copyChapterPgnAt(i)),
    onClearAnnotations: (i) => unawaited(_clearAnnotationsAt(i)),
    onClearVariations: (i) => unawaited(_clearVariationsAt(i)),
    onDelete: (i) => unawaited(_deleteChapterAt(i)),
  );

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
      editChapter: _editChapterAt,
    );
    if (mounted) setState(() {});
  }

  Future<void> _editChapterAt(int index) async {
    final edit = await showEditChapterDialog(
      context,
      chapter: _study.doc.chapters[index],
    );
    if (edit == null) return;
    _study.updateChapter(
      index,
      name: edit.name,
      orientation: edit.orientation,
      headers: edit.headers,
    );
  }

  Future<void> _copyChapterPgnAt(int index) async {
    await Clipboard.setData(ClipboardData(text: _study.chapterPgn(index)));
    if (mounted) showAppSnackBar(context, 'Chapter PGN copied to clipboard.');
  }

  Future<void> _clearAnnotationsAt(int index) async {
    final confirmed = await confirmAction(
      context,
      title: 'Clear all comments, glyphs and shapes?',
      message:
          'Every note in "${_study.doc.chapters[index].name}" goes; the '
          'moves stay.',
      confirmLabel: 'Clear',
    );
    if (confirmed) _study.clearChapterAnnotations(index);
  }

  Future<void> _clearVariationsAt(int index) async {
    final confirmed = await confirmAction(
      context,
      title: 'Clear variations?',
      message:
          'Every sideline in "${_study.doc.chapters[index].name}" goes; '
          'the main line and its notes stay.',
      confirmLabel: 'Clear',
    );
    if (confirmed) _study.clearChapterVariations(index);
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
    final confirmed = await confirmAction(
      context,
      title: 'Delete chapter "${_study.doc.chapters[index].name}"?',
      confirmLabel: 'Delete',
    );
    if (confirmed) _study.deleteChapter(index);
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: AppBarTitleWithTrail(
          title: StudyPickerBar(
            study: _study,
            focusNode: _focusNode,
            onPickStudy: () => unawaited(_pickStudy()),
          ),
        ),
        actions: [
          // Only visible while a collection download is running.
          const StudyImportStatusChip(),
          AppOverflowMenu(
            entries: [
              AppMenuEntry(
                heading: 'Study',
                label: 'New study',
                onRun: () => unawaited(_newStudy()),
              ),
              AppMenuEntry(
                heading: 'Import',
                label: 'From URL…',
                onRun: () => unawaited(_importFromUrl()),
              ),
              AppMenuEntry(
                label: 'PGN file as chapters…',
                onRun: () => unawaited(_importPgn()),
              ),
              if (_study.doc.filePath != null) ...[
                AppMenuEntry(
                  heading: 'Export',
                  label: 'Copy study PGN',
                  onRun: () => unawaited(_exportPgn()),
                ),
                AppMenuEntry(
                  label: 'Save study PGN as…',
                  onRun: () => unawaited(_saveStudyAs()),
                ),
              ],
              AppMenuEntry(
                heading: 'Train',
                label: 'Train this chapter',
                onRun: () => _train(wholeStudy: false),
              ),
              AppMenuEntry(
                label: 'Train whole study',
                onRun: () => _train(wholeStudy: true),
              ),
              AppMenuEntry(
                heading: 'Board',
                label: 'Flip board',
                onRun: _study.toggleFlipped,
              ),
              AppMenuEntry(
                heading: 'Explore',
                label: 'Browse in PGN viewer',
                enabled: _study.doc.filePath != null,
                shortcut: 'A',
                onRun: _browseInViewer,
              ),
              if (_study.doc.filePath != null)
                AppMenuEntry(
                  heading: 'Manage',
                  label: 'Delete study…',
                  onRun: () => unawaited(_deleteCurrentStudy()),
                ),
            ],
          ),
          const AppModeSwitcher(),
          const AppSettingsButton(mode: AppMode.study),
        ],
      ),
      body: TrainerKeyboardScope(
        holdsFocus: true,
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < kCompactBreakpoint;
            final board = StudyBoardPane(
              study: _study,
              moveInputKey: _moveInputKey,
              keyBindings: _keyBindings,
              // Shapes on the start position go into the chapter's
              // introduction comment, as they do on Lichess.
              onShapeDrawn: (orig, dest) => applyStudyBoardShape(
                _study,
                orig,
                dest,
                brush: studyShapeBrushFromKeyboard(),
              ),
            );
            final side = StudySidePane(
              study: _study,
              compact: compact,
              onEngineLine: _addEngineLine,
              onAddChapter: () => unawaited(_newChapter()),
              onPickChapter: () => unawaited(_pickChapter()),
              onManageChapters: () => unawaited(_manageChapters()),
              actions: _chapterActions,
            );
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
                          onAddChapter: () => unawaited(_newChapter()),
                          actions: _chapterActions,
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
}
