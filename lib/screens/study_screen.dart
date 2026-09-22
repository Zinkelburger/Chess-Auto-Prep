/// Study mode — composition root: [StudyController] plus board, PGN editor,
/// chapter sidebar, and engine. Layout widgets live under `widgets/study/`.
library;

import '../features/studies/repositories/study_import_repository.dart';

import '../l10n/study_import_labels.dart';
import '../features/studies/models/study_import_state.dart';

import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../features/studies/controllers/study_controller.dart';
import '../features/studies/widgets/study_save_button.dart';
import '../features/studies/widgets/study_selector.dart';
import '../features/documents/widgets/document_save_dialog.dart';
import '../design_system/components/name_entry_dialog.dart';
import '../l10n/generated/app_localizations.dart';
import '../chess_core/moves/tree_path.dart';
import '../chess_core/pgn/repertoire_line_ids.dart';
import '../chess_core/pgn/mainline_lexer.dart' as pgn;
import '../features/studies/controllers/study_import_controller.dart';
import '../utils/app_messages.dart';
import '../utils/app_shortcuts.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/board_editor/board_editor_dialog.dart';
import '../design_system/components/confirm_dialog.dart';
import '../models/pgn_deletion_summary.dart';
import '../widgets/pgn/pgn_save_status.dart';
import '../widgets/common/searchable_picker_dialog.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
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
import '../widgets/board_keyboard_scope.dart';
import '../widgets/training/move_input_widget.dart';

class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  late final StudyController _study;
  final FocusScopeNode _focusNode = FocusScopeNode(
    debugLabel: 'study keyboard',
  );
  final GlobalKey<MoveInputWidgetState> _moveInputKey = GlobalKey();

  AppState? _appStateRef;

  /// Background collection downloads. App-wide, because a run outlives this
  /// screen — [_seenImportGeneration] is seeded so a run that finished before
  /// the screen existed is not re-announced.
  late final StudyImportController _import;
  late int _seenImportGeneration;

  @override
  void initState() {
    super.initState();
    _study = context.read<StudyController>();
    _import = context.read<StudyImportController>();
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

  int _handoffEpoch = 0;
  Future<void> _openFromHandoff(EditStudy handoff) async {
    final epoch = ++_handoffEpoch;
    bool opened;
    try {
      opened = await _study.openStudy(handoff.studyPath);
    } catch (_) {
      if (mounted && epoch == _handoffEpoch) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).studyOpenFailed,
          isError: true,
        );
      }
      return;
    }
    if (!mounted || epoch != _handoffEpoch || !opened) return;
    final chapterIndex = handoff.chapterIndex;
    final chapterName = handoff.chapterName;
    if (chapterIndex != null && _study.chapterList.chapters.isNotEmpty) {
      // Browse↔Edit toggle: the producer showed this same file, index is
      // exact.
      _study.selectChapter(
        chapterIndex.clamp(0, _study.chapterList.chapters.length - 1),
      );
    } else if (chapterName != null) {
      // Last match: add-to-study appends, and names aren't unique.
      final index = _study.chapterList.chapters.lastIndexWhere(
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
    _focusNode.dispose();
    super.dispose();
  }

  // ── Keyboard ─────────────────────────────────────────────────────────

  /// Study-mode shortcuts, dispatched through [handleKeyBindings] (never
  /// while typing).
  List<KeyBinding> get _keyBindings => [
    ...KeyBinding.forShortcut(
      AppShortcut.backOneMove,
      AppLocalizations.of(context).studyBackMove,
      _study.goBack,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.forwardOneMove,
      AppLocalizations.of(context).studyForwardMove,
      _study.goForward,
      repeats: true,
    ),
    // Home/End jump to the line's ends (as in the PGN viewer); ↑/↓
    // step the queue in front of you, which here is the chapter list.
    ...KeyBinding.forShortcut(
      AppShortcut.goToStart,
      AppLocalizations.of(context).studyGoStart,
      _study.goToStart,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.goToEnd,
      AppLocalizations.of(context).studyGoEnd,
      _study.goToEnd,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.toggleEngine,
      AppLocalizations.of(context).studyToggleEngine,
      () => InlineEngineBar.toggleEngine(context),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.flipBoard,
      AppLocalizations.of(context).studyFlipBoard,
      _study.toggleFlipped,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.browseInViewer,
      AppLocalizations.of(context).studyBrowsePgn,
      _browseInViewer,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.nextItem,
      AppLocalizations.of(context).studyNextChapter,
      () => _study.selectChapter(_study.chapterIndex + 1),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.previousItem,
      AppLocalizations.of(context).studyPreviousChapter,
      () => _study.selectChapter(_study.chapterIndex - 1),
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.focusMoveInput,
      AppLocalizations.of(context).studyFocusInput,
      () => _moveInputKey.currentState?.focus(),
    ),
    // Jump into the annotation panel's comment field for the current move.
    ...KeyBinding.forShortcutIf(
      AppShortcut.commentMove,
      AppLocalizations.of(context).studyCommentCurrent,
      PgnAnnotationPanel.focusActive,
    ),
  ];

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
    final name = await promptStudyName(
      context,
      title: AppLocalizations.of(context).studyNewStudy,
    );
    if (name == null) return;
    try {
      await _study.newStudy(name);
    } on ArgumentError {
      if (mounted)
        showAppSnackBar(
          context,
          AppLocalizations.of(context).studyNameExists,
          isError: true,
        );
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
    final session = _study.title.session;
    await ImportFromUrlDialog.show(
      context,
      canAppend: _study.title.filePath != null,
      repository: context.read<StudyImportRepository>(),
      apply: (plan) async {
        if (!mounted) return false;
        if (plan is LichessStudyPlan) {
          if (plan.appendToCurrent && session != _study.title.session) {
            return false;
          }
          return _applyLichessPlan(plan);
        }
        return _startCollectionDownload(plan as CollectionPlan);
      },
    );
  }

  Future<bool> _applyLichessPlan(LichessStudyPlan plan) async {
    final session = _study.title.session;
    final chapters = _study.chapterList.chapters.length;
    var consumed = false;
    try {
      if (plan.appendToCurrent) {
        final added = await _study.importChapters(plan.pgn);
        if (!mounted || session != _study.title.session) return true;
        final l10n = AppLocalizations.of(context);
        showAppSnackBar(context, l10n.studyImportAdded(added));
        return true;
      }
      final result = await _import.publishStudy(name: plan.name, pgn: plan.pgn);
      consumed = true;
      // The result listener reports the captured publication, not whichever
      // study happens to be active when this asynchronous operation completes.
      if (mounted &&
          session == _study.title.session &&
          result.studyPath != null) {
        await _study.openStudy(result.studyPath!);
      }
      return true;
    } catch (error) {
      if (!mounted) return false;
      final l10n = AppLocalizations.of(context);
      showAppSnackBar(
        context,
        error is StudyImportRejected
            ? studyImportFailureLabel(l10n, error.failure)
            : l10n.studyImportApplyFailed,
        isError: true,
      );
      // Appended chapters already belong to the editor even if autosave failed;
      // resubmitting them would duplicate work. A rejected create stays in-dialog.
      return consumed ||
          (plan.appendToCurrent &&
              session == _study.title.session &&
              _study.chapterList.chapters.length > chapters);
    }
  }

  bool _startCollectionDownload(CollectionPlan plan) {
    final rejection = _import.admissionFailure;
    if (rejection != null) {
      showAppSnackBar(
        context,
        studyImportFailureLabel(
          AppLocalizations.of(context),
          rejection.failure,
        ),
        isError: true,
      );
      return false;
    }
    final minutes = (plan.gameIds.length * plan.delay.inSeconds / 60)
        .ceil()
        .clamp(1, 9999);
    // Deliberately not awaited: the application owns this background job.
    unawaited(
      _import
          .startCollectionDownload(
            gameIds: plan.gameIds,
            studyName: plan.studyName,
            delay: plan.delay,
          )
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              if (!mounted) return;
              showAppSnackBar(
                context,
                studyImportFailureLabel(
                  AppLocalizations.of(context),
                  error is StudyImportRejected
                      ? error.failure
                      : StudyImportFailure.startup,
                ),
                isError: true,
              );
            },
          ),
    );
    showAppSnackBar(
      context,
      AppLocalizations.of(
        context,
      ).studyImportBackground(plan.gameIds.length, minutes),
      requiresAttention: true,
    );
    return true;
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

    final l10n = AppLocalizations.of(context);
    final failure = result.failure;
    final message = failure != null
        ? studyImportFailureLabel(l10n, failure)
        : !result.wroteAnything
        ? l10n.studyImportNoContent(result.failed)
        : result.cancelled
        ? l10n.studyImportStopped(result.chapters, result.studyName)
        : l10n.studyImportComplete(
            result.chapters,
            result.failed,
            result.studyName,
          );
    final publication = result.publication;
    final review = publication != null && !result.wroteAnything;
    showAppSnackBar(
      context,
      message,
      isError: failure != null,
      requiresAttention: true,
      actionLabel: review
          ? l10n.studyImportReviewAction
          : result.wroteAnything
          ? l10n.studyImportOpen
          : null,
      onAction: review
          ? _reviewImportedStudy
          : result.wroteAnything
          ? () => _study.openStudy(result.studyPath!)
          : null,
    );
  }

  Future<void> _reviewImportedStudy() async {
    final session = _import.publicationRecovery;
    if (session == null) return;
    await showDocumentSaveDialog(
      context,
      title: AppLocalizations.of(context).studyImportReview,
      session: session,
      chooseCopyDestination: _chooseExportDestination,
    );
    if (mounted && !session.state.dirty && !session.state.uncertain) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  /// Open a PGN file from disk: every game becomes a chapter appended to
  /// the study.  (Pasting PGN is the "New chapter" dialog's job.)
  Future<void> _importPgn() async {
    final session = _study.title.session;
    final file = await FilePicker.pickFile(
      dialogTitle: AppLocalizations.of(context).studyImportPgnChapters,
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
    );
    final path = file?.path;
    if (path == null || !mounted || session != _study.title.session) return;
    if (!mounted) return;
    try {
      final added = await _study.importFile(path);
      if (mounted && added > 0) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).studyAddedChapters(added),
        );
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).studyImportPgnFailed,
          isError: true,
        );
      }
    }
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
          ? AppLocalizations.of(context).studyNoPgnGames
          : AppLocalizations.of(context).studyAddedChapters(added),
      isError: added == 0,
    );
  }

  /// Copy the whole study (all chapters) as PGN to the clipboard.
  Future<void> _exportPgn() async {
    await _study.flushSave();
    await Clipboard.setData(ClipboardData(text: _study.doc.toPgn()));
    if (mounted) {
      showAppSnackBar(context, AppLocalizations.of(context).studyPgnCopied);
    }
  }

  /// Export is an exclusive typed write; a picker never writes bytes itself.
  /// Its independent save session leaves the source document and draft intact.
  Future<void> _saveStudyAs() async {
    final destination = await _chooseExportDestination(context);
    if (!mounted || destination == null) return;
    final session = _study.exportSession(destination);
    unawaited(session.save());
    try {
      await showDocumentSaveDialog(
        context,
        title: AppLocalizations.of(context).studyExportTitle,
        session: session,
        chooseCopyDestination: _chooseExportDestination,
      );
    } finally {
      await session.dispose();
    }
  }

  Future<String?> _chooseExportDestination(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: l10n.studyExportDirectory,
    );
    if (directory == null || !context.mounted) return null;
    final name = await showNameEntryDialog(
      context,
      title: l10n.studyExportTitle,
      fieldLabel: l10n.studyExportName,
      initialValue: '${_study.title.name}.pgn',
      allowUnchanged: true,
      confirmLabel: l10n.saveCopy,
      cancelLabel: l10n.cancel,
      validate: (value) =>
          value == '.' ||
              value == '..' ||
              RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(value)
          ? l10n.studyInvalidName
          : null,
    );
    if (name == null) return null;
    return p.join(
      directory,
      name.toLowerCase().endsWith('.pgn') ? name : '$name.pgn',
    );
  }

  Future<void> _deleteCurrentStudy() async {
    final doc = _study.doc;
    final path = doc.filePath;
    if (path == null) return;
    final chapters = List.of(doc.chapters);
    final summaries = [
      for (final c in chapters) PgnDeletionSummary.tree(c.tree),
    ];
    final moves = summaries.fold(0, (n, s) => n + s.moves);
    final comments = summaries.fold(0, (n, s) => n + s.comments);
    final confirmed = await confirmAction(
      context,
      title: AppLocalizations.of(context).studyDeleteNamed(doc.name),
      message: AppLocalizations.of(
        context,
      ).studyDeleteContents(chapters.length, moves, comments),
      confirmLabel: AppLocalizations.of(context).delete,
    );
    if (!mounted ||
        !confirmed ||
        !identical(_study.doc, doc) ||
        doc.chapters.length != chapters.length) {
      return;
    }
    await _study.deleteStudy(path);
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
    final chapter = _study.chapter;
    if (_study.chapterHasMoves) {
      final confirmed = await confirmAction(
        context,
        title: AppLocalizations.of(context).studyReplacePosition,
        message: AppLocalizations.of(
          context,
        ).studyReplacePositionContents(_study.chapter.name),
        confirmLabel: AppLocalizations.of(context).studyReplace,
        destructive: false,
      );
      if (!confirmed) return;
    }
    if (!mounted) return;
    final position = await BoardEditorDialog.show(
      context,
      initialFen: _study.currentPosition.fen,
      actionLabel: AppLocalizations.of(context).studySetPosition,
    );
    if (!mounted || position == null || _study.chapter != chapter) return;
    _study.setChapterStartingPosition(position.fen);
  }

  /// Train this study (or just the current chapter) in the Repertoire
  /// Trainer's tactics mode: each chapter is one puzzle — starting FEN,
  /// solution mainline, comments shown as annotations.
  Future<void> _train({required bool wholeStudy}) async {
    final path = _study.title.filePath;
    if (path == null) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context).studySaveFirst,
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
            ? AppLocalizations.of(context).studyNoTrainingChapters
            : AppLocalizations.of(context).studyNoTrainingMoves,
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
      final text = _study.chapterPgn(_study.chapterIndex);
      final moves = pgn.mainlineSansOf(text);
      lineId =
          (moves.isEmpty
              ? null
              : repertoireLineIds.fromHeaders(
                  pgn.extractHeaderBlock(text),
                  moves,
                  _study.chapterIndex,
                )) ??
          repertoireLineIds.stable(
            _study.tree.sanSequenceAt(
              _study.tree.mainlineEndFrom(TreePath.empty),
            ),
            _study.chapterIndex,
          );
    }
    final revision = _study.navigationRevision;
    final chapter = _study.chapterIndex;
    if (!await _study.flushSave() ||
        !mounted ||
        _study.title.filePath != path ||
        _study.chapterIndex != chapter ||
        _study.navigationRevision != revision) {
      return;
    }
    context.read<AppState>().switchToStudyTraining(path: path, lineId: lineId);
  }

  void _onChapterAction(ChapterAction action, int index) {
    if (!mounted) return;
    unawaited(switch (action) {
      ChapterAction.edit => _editChapterAt(index),
      ChapterAction.setStartingPosition => _setStartingPositionAt(index),
      ChapterAction.copyPgn => _copyChapterPgnAt(index),
      ChapterAction.clearAnnotations => _clearAnnotationsAt(index),
      ChapterAction.clearVariations => _clearVariationsAt(index),
      ChapterAction.delete => _deleteChapterAt(index),
    });
  }

  /// The Edit↔Browse toggle: reopen this study as a game collection in the
  /// PGN viewer, parked on the same chapter. The viewer's own toggle comes
  /// straight back here.
  Future<void> _browseInViewer() async {
    final path = _study.title.filePath;
    if (path == null) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context).studySaveFirst,
        isError: true,
      );
      return;
    }
    final chapter = _study.chapterIndex;
    final revision = _study.navigationRevision;
    if (!await _study.flushSave() ||
        !mounted ||
        _study.title.filePath != path ||
        _study.chapterIndex != chapter ||
        _study.navigationRevision != revision) {
      return;
    }
    context.read<AppState>().switchToPgnViewer(
      path: path,
      gameIndex: _study.chapterIndex,
      historyLabel: AppLocalizations.of(
        context,
      ).studyPgnHistory(_study.title.name),
    );
  }

  Future<void> _manageChapters() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 520,
          height: 600,
          child: Column(
            children: [
              Expanded(
                child: StudyChapterSidebar(
                  study: _study,
                  inlineActions: true,
                  onChapterAction: _onChapterAction,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(
                    AppLocalizations.of(dialogContext).studyChaptersDone,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editChapterAt(int index) async {
    final chapter = _study.chapterAt(index);
    final edit = await showEditChapterDialog(context, chapter: chapter);
    if (!mounted || edit == null) return;
    final currentIndex = _study.indexOfChapter(chapter);
    if (currentIndex < 0) return;
    _study.updateChapter(
      currentIndex,
      name: edit.name,
      orientation: edit.orientation,
      headers: edit.headers,
    );
  }

  Future<void> _copyChapterPgnAt(int index) async {
    await Clipboard.setData(ClipboardData(text: _study.chapterPgn(index)));
    if (mounted) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context).studyChapterPgnCopied,
      );
    }
  }

  Future<void> _clearAnnotationsAt(int index) async {
    final chapter = _study.chapterAt(index);
    final summary = PgnDeletionSummary.tree(chapter.tree);
    final confirmed = await confirmAction(
      context,
      title: AppLocalizations.of(context).studyClearAnnotations,
      message: AppLocalizations.of(
        context,
      ).studyClearAnnotationContents(summary.comments, chapter.name),
      confirmLabel: AppLocalizations.of(context).clear,
    );
    if (!mounted || !confirmed) return;
    final currentIndex = _study.indexOfChapter(chapter);
    if (currentIndex >= 0) _study.clearChapterAnnotations(currentIndex);
  }

  Future<void> _clearVariationsAt(int index) async {
    final chapter = _study.chapterAt(index);
    final summary = PgnDeletionSummary.variations(chapter.tree);
    final confirmed = await confirmAction(
      context,
      title: AppLocalizations.of(context).studyClearVariations,
      message: AppLocalizations.of(context).studyClearVariationContents(
        summary.moves,
        summary.comments,
        chapter.name,
      ),
      confirmLabel: AppLocalizations.of(context).clear,
    );
    if (!mounted || !confirmed) return;
    final currentIndex = _study.indexOfChapter(chapter);
    if (currentIndex >= 0) _study.clearChapterVariations(currentIndex);
  }

  /// Gear action on a sidebar row: the board-editor flow edits the *current*
  /// chapter, so switch to that chapter first.
  Future<void> _setStartingPositionAt(int index) async {
    _study.selectChapter(index);
    await _editChapterPosition();
  }

  Future<void> _deleteChapterAt(int index) async {
    if (_study.chapterList.chapters.length <= 1) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context).studyNeedsChapter,
        isError: true,
      );
      return;
    }
    final chapter = _study.chapterAt(index);
    final summary = PgnDeletionSummary.tree(chapter.tree);
    final confirmed = await confirmAction(
      context,
      title: AppLocalizations.of(context).studyDeleteChapterNamed(chapter.name),
      message: AppLocalizations.of(
        context,
      ).studyRemoveCounts(summary.moves, summary.comments),
      confirmLabel: AppLocalizations.of(context).delete,
    );
    if (!mounted || !confirmed) return;
    final currentIndex = _study.indexOfChapter(chapter);
    if (currentIndex >= 0) _study.deleteChapter(currentIndex);
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BoardKeyboardScope(
      moveInputKey: _moveInputKey,
      bindings: () => _keyBindings,
      focusNode: _focusNode,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(
            children: [
              Flexible(
                child: AppBarTitleWithTrail(
                  title: StudyPickerBar(
                    study: _study,
                    focusNode: _focusNode,
                    onPickStudy: () => unawaited(_pickStudy()),
                  ),
                ),
              ),
              Flexible(
                child:
                    StudySelector<
                      ({
                        String? path,
                        bool autoSave,
                        bool saving,
                        bool dirty,
                        String? error,
                      })
                    >(
                      study: _study,
                      select: (owner) => (
                        path: owner.title.filePath,
                        autoSave: owner.autoSaveEnabled,
                        saving: owner.state.busy,
                        dirty: owner.dirty,
                        error: owner.saveError,
                      ),
                      builder: (context, view) => view.path == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: PgnSaveStatus(
                                filePath: view.path,
                                autoSave: view.autoSave,
                                saving: view.saving,
                                dirty: view.dirty,
                                error: view.error,
                              ),
                            ),
                    ),
              ),
            ],
          ),
          actions: [
            StudySaveButton(study: _study),
            // Only visible while a collection download is running.
            StudyImportStatusChip(
              controller: _import,
              onReview: _reviewImportedStudy,
            ),
            StudySelector<bool>(
              study: _study,
              select: (owner) => owner.title.filePath != null,
              builder: (context, hasFile) => AppOverflowMenu(
                entries: [
                  AppMenuEntry(
                    heading: l10n.studyWorkspaceName,
                    label: l10n.studyNewStudy,
                    icon: Icons.library_add_outlined,
                    onRun: () => unawaited(_newStudy()),
                  ),
                  AppMenuEntry(
                    heading: l10n.importAction,
                    label: l10n.studyFromUrl,
                    icon: Icons.link,
                    onRun: () => unawaited(_importFromUrl()),
                  ),
                  AppMenuEntry(
                    label: l10n.studyPgnFileChapters,
                    icon: Icons.description_outlined,
                    onRun: () => unawaited(_importPgn()),
                  ),
                  if (hasFile) ...[
                    AppMenuEntry(
                      heading: l10n.studyExportHeading,
                      label: l10n.studyCopyPgn,
                      icon: Icons.copy,
                      onRun: () => unawaited(_exportPgn()),
                    ),
                    AppMenuEntry(
                      label: l10n.studySavePgnAs,
                      icon: Icons.description_outlined,
                      onRun: () => unawaited(_saveStudyAs()),
                    ),
                  ],
                  AppMenuEntry(
                    heading: l10n.studyTrainHeading,
                    label: l10n.studyTrainChapter,
                    icon: Icons.school_outlined,
                    onRun: () => _train(wholeStudy: false),
                  ),
                  AppMenuEntry(
                    label: l10n.studyTrainAll,
                    icon: Icons.school_outlined,
                    onRun: () => _train(wholeStudy: true),
                  ),
                  AppMenuEntry(
                    heading: l10n.studyBoardHeading,
                    label: l10n.studyFlipBoard,
                    icon: Icons.swap_vert,
                    onRun: _study.toggleFlipped,
                  ),
                  AppMenuEntry(
                    heading: l10n.studyExploreHeading,
                    label: l10n.studyBrowsePgn,
                    icon: Icons.open_in_new,
                    enabled: hasFile,
                    onRun: _browseInViewer,
                  ),
                  if (hasFile)
                    AppMenuEntry(
                      heading: l10n.studyManageHeading,
                      label: l10n.studyDeleteMenu,
                      icon: Icons.delete_outline,
                      onRun: () => unawaited(_deleteCurrentStudy()),
                    ),
                ],
              ),
            ),
            const AppModeSwitcher(),
            const AppSettingsButton(mode: AppMode.study),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < kCompactBreakpoint;
            final board = StudyBoardPane(
              study: _study,
              moveInputKey: _moveInputKey,
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
              onChapterAction: _onChapterAction,
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
                          onChapterAction: _onChapterAction,
                        ),
                      ),
                      const VerticalDivider(width: 1, thickness: 1),
                      Expanded(flex: 5, child: board),
                      const VerticalDivider(width: 1, thickness: 1),
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
    final current = _study.title;
    final picked = await showSearchablePicker<String>(
      context: context,
      title: AppLocalizations.of(context).studySwitch,
      searchHint: AppLocalizations.of(context).studySearch,
      selected: current.filePath,
      items: [
        for (final study in _study.availableStudies)
          PickerItem(
            value: study.filePath,
            label: study.name,
            subtitle: AppLocalizations.of(
              context,
            ).studyChapterCount(study.gameCount),
            icon: Icons.menu_book_outlined,
          ),
      ],
      emptyMessage: AppLocalizations.of(context).studyNoStudies,
    );
    if (mounted &&
        picked != null &&
        picked != current.filePath &&
        _study.title.session == current.session) {
      await _study.openStudy(picked);
    }
  }

  Future<void> _pickChapter() async {
    final list = _study.chapterList;
    final picked = await showSearchablePicker<Object>(
      context: context,
      title: AppLocalizations.of(context).studyGoChapter,
      searchHint: AppLocalizations.of(context).studySearchChapters,
      selected: list.chapters[_study.chapterIndex].key,
      items: [
        for (final (i, chapter) in list.chapters.indexed)
          PickerItem(
            value: chapter.key,
            label: chapter.name,
            subtitle: AppLocalizations.of(context).studyChapterNumber(i + 1),
            icon: Icons.bookmark_outline,
          ),
      ],
      emptyMessage: AppLocalizations.of(context).studyNoChaptersYet,
    );
    if (!mounted || picked == null || _study.title.session != list.session) {
      return;
    }
    final index = _study.chapterList.chapters.indexWhere(
      (chapter) => chapter.key == picked,
    );
    if (index >= 0) _study.selectChapter(index);
  }
}
