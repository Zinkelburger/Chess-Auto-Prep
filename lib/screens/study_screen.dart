/// Study mode — general chess study: annotated move trees with variations
/// and comments, multiple chapters per study file, engine analysis, and a
/// board editor for custom starting positions.
///
/// Assembly of existing parts: [StudyController] (state) + board +
/// [InteractivePgnEditor] (move tree view) + [InlineEngineBar] (engine).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants/ui_breakpoints.dart';
import '../core/app_state.dart';
import '../core/study_controller.dart';
import '../utils/app_messages.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/board_editor/board_editor_dialog.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/interactive_pgn_editor.dart';
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

  @override
  void initState() {
    super.initState();
    _study = context.read<StudyController>();
    _study.addListener(_onStudyChanged);
    _study.refreshStudyList();
  }

  @override
  void dispose() {
    _study.removeListener(_onStudyChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onStudyChanged() {
    if (mounted) setState(() {});
  }

  // ── Keyboard ─────────────────────────────────────────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || isTextInputFocused()) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _study.goBack();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _study.goForward();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _study.goToStart();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _study.goToEnd();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE && hasNoLetterModifiers) {
      InlineEngineBar.toggleEngine();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF && hasNoLetterModifiers) {
      _study.toggleFlipped();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash) {
      _moveInputKey.currentState?.focus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('OK')),
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
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
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
              'new starting position will clear them.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Replace')),
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

  /// Load the current chapter into the PGN viewer and quiz the whole line
  /// via solitaire ("a study is positions we get quizzed on").
  Future<void> _trainChapter() async {
    if (!_study.chapterHasMoves) {
      showAppSnackBar(context, 'This chapter has no moves to train yet.',
          isError: true);
      return;
    }
    await _study.flushSave();
    if (!mounted) return;
    context.read<AppState>().switchToSolitaireTraining(
          pgn: _study.chapterPgn(),
          asWhite: !_study.flipped,
        );
  }

  Future<void> _renameChapter() async {
    final name =
        await _promptName('Rename chapter', initial: _study.chapter.name);
    if (name == null) return;
    _study.renameChapter(_study.chapterIndex, name);
  }

  Future<void> _deleteChapter() async {
    if (_study.doc.chapters.length <= 1) {
      showAppSnackBar(context, 'A study needs at least one chapter.',
          isError: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete chapter "${_study.chapter.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _study.deleteChapter(_study.chapterIndex);
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Study'),
            const SizedBox(width: 16),
            _buildStudyPicker(),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: 'Board editor — set chapter starting position',
            onPressed: _editChapterPosition,
          ),
          IconButton(
            icon: const Icon(Icons.school_outlined, size: 20),
            tooltip: 'Train this chapter (solitaire)',
            onPressed: _trainChapter,
          ),
          IconButton(
            icon: const Icon(Icons.swap_vert, size: 20),
            tooltip: 'Flip board (F)',
            onPressed: _study.toggleFlipped,
          ),
          IconButton(
            icon: const Icon(Icons.extension, size: 20),
            tooltip: 'Make puzzle from this position',
            onPressed: () {
              context.read<AppState>().switchToPuzzleCreator(
                  seedFen: _study.currentPosition.fen);
            },
          ),
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
            final side = _buildSidePane();
            return compact
                ? Column(children: [
                    Expanded(flex: 5, child: board),
                    const Divider(height: 1),
                    Expanded(flex: 4, child: side),
                  ])
                : Row(children: [
                    Expanded(flex: 5, child: board),
                    Container(width: 1, color: Colors.grey[700]),
                    Expanded(flex: 4, child: side),
                  ]);
          },
        ),
      ),
    );
  }

  Widget _buildStudyPicker() {
    final theme = Theme.of(context);
    final current = _study.doc;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: DropdownButton<String>(
            value: current.filePath,
            hint: Text(current.name, style: theme.textTheme.bodyMedium),
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final study in _study.availableStudies)
                DropdownMenuItem(
                  value: study.filePath,
                  child: Text(
                    study.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (path) {
              if (path != null && path != current.filePath) {
                _study.openStudy(path);
              }
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          tooltip: 'New study',
          onPressed: _newStudy,
        ),
        if (current.filePath != null)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            tooltip: 'Manage studies',
            onSelected: (action) {
              switch (action) {
                case 'delete':
                  _deleteCurrentStudy();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'delete', child: Text('Delete study…')),
            ],
          ),
      ],
    );
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
            ),
          ),
          const SizedBox(height: 8),
          InlineEngineBar(fen: _study.currentPosition.fen),
        ],
      ),
    );
  }

  Widget _buildSidePane() {
    final theme = Theme.of(context);
    return Column(
      children: [
        // Chapter bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Icon(Icons.bookmark_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  value: _study.chapterIndex,
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final (i, chapter) in _study.doc.chapters.indexed)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          chapter.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (i) {
                    if (i != null) _study.selectChapter(i);
                  },
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
                tooltip: 'Manage chapters',
                onSelected: (action) {
                  switch (action) {
                    case 'train':
                      _trainChapter();
                    case 'add_from_position':
                      _addChapter(fromPosition: true);
                    case 'set_position':
                      _editChapterPosition();
                    case 'rename':
                      _renameChapter();
                    case 'delete':
                      _deleteChapter();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'train', child: Text('Train this chapter')),
                  PopupMenuDivider(),
                  PopupMenuItem(
                      value: 'add_from_position',
                      child: Text('New chapter from position…')),
                  PopupMenuItem(
                      value: 'set_position',
                      child: Text('Set starting position…')),
                  PopupMenuItem(
                      value: 'rename', child: Text('Rename chapter…')),
                  PopupMenuItem(
                      value: 'delete', child: Text('Delete chapter…')),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: InteractivePgnEditor(
              tree: _study.tree,
              currentPath: _study.cursor,
              currentRepertoireName: _study.chapter.name,
              onJump: _study.jumpTo,
              onCommentChanged: _study.setComment,
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
