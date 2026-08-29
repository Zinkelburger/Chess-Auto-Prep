/// Read-only "book view" of a whole chapter: one board beside every line in
/// the chapter, laid out as a scrolling course page — heading, annotated
/// movetext, next heading — instead of one dialog per line.
///
/// Click any move to put it on the board. ←/→ step through the line under the
/// cursor and roll over into the next line at the move where it departs from
/// the one just read, so a chapter can be read end to end with one key.
/// Never touches training or review state; "Train this line" hands off to the
/// trainer after closing.
library;

import 'dart:async' show unawaited;

import 'package:dartchess/dartchess.dart' show PgnGame, Position, Side;
import 'package:flutter/material.dart';

import '../../core/pgn/viewer_game_model.dart';
import '../../models/line_status.dart';
import '../../models/move_tree.dart';
import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_shortcuts.dart';
import '../../utils/keyboard_shortcut_utils.dart';
import '../chess_board_widget.dart';
import '../pgn/pgn_movetext_view.dart';
import '../shortcut_tooltip.dart';
import '../trainer_keyboard_scope.dart';

class ChapterReaderScreen extends StatefulWidget {
  /// Repertoire or study name — the first half of the app-bar title.
  final String repertoireName;

  /// Chapter title — the second half ("All lines" for a file without
  /// chapters).
  final String chapterTitle;

  /// Lines in file order. Model games are welcome: they are read, not
  /// drilled, so they get no Train button.
  final List<RepertoireLine> lines;

  final Map<String, RepertoireReviewEntry> reviewMap;

  /// Line to open on, or null for the first.
  final String? initialLineId;

  /// Start drilling a line. The reader closes itself first.
  final void Function(RepertoireLine line)? onTrainLine;

  /// Label for the edit handoff ("Edit in Builder" / "Edit in Study").
  final String editLabel;

  /// Open a line for editing. The reader closes itself first.
  final void Function(RepertoireLine line)? onEditLine;

  const ChapterReaderScreen({
    super.key,
    required this.repertoireName,
    required this.chapterTitle,
    required this.lines,
    this.reviewMap = const {},
    this.initialLineId,
    this.onTrainLine,
    this.editLabel = 'Edit',
    this.onEditLine,
  });

  @override
  State<ChapterReaderScreen> createState() => _ChapterReaderScreenState();
}

/// One line of the chapter as the reader sees it: its parsed game (or why it
/// failed to parse) and the heading key used to scroll to it.
class _ReaderSection {
  final RepertoireLine line;
  final ViewerGameModel? model;
  final String? parseError;
  final GlobalKey headingKey = GlobalKey();

  _ReaderSection(this.line, {this.model, this.parseError});

  int get length => model?.moveHistory.length ?? 0;

  /// Mainline SANs as the movetext shows them (the parsed game, not the
  /// line's own summary, so navigation and rendering can never disagree).
  List<String> get sans => model == null
      ? line.moves
      : [for (final data in model!.moveHistory) data.san];

  static _ReaderSection parse(RepertoireLine line) {
    try {
      final model = ViewerGameModel()..load(PgnGame.parsePgn(line.fullPgn));
      return _ReaderSection(line, model: model);
    } catch (e) {
      return _ReaderSection(line, parseError: '$e');
    }
  }
}

class _ChapterReaderScreenState extends State<ChapterReaderScreen> {
  late final List<_ReaderSection> _sections = [
    for (final line in widget.lines) _ReaderSection.parse(line),
  ];

  late int _active = () {
    final wanted = widget.initialLineId;
    if (wanted == null) return 0;
    final index = widget.lines.indexWhere((line) => line.id == wanted);
    return index < 0 ? 0 : index;
  }();

  late bool _flipped =
      widget.lines.isNotEmpty &&
      widget.lines[_active].color.toLowerCase() == 'black';

  final FocusNode _focusNode = FocusNode(debugLabel: 'chapter-reader');
  final ScrollController _scroll = ScrollController();

  /// Attached to the current move of the active section so navigation can
  /// keep it on screen.
  final GlobalKey _currentMoveKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Land on the opening line's heading, not the top of the page, when the
    // reader was opened on a specific line.
    if (_active > 0) _scrollIntoView(atStart: true);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _ReaderSection? get _current => _sections.isEmpty ? null : _sections[_active];

  Position get _position {
    final section = _current;
    if (section == null) return widget.lines.first.startPosition;
    return section.model?.currentPosition ?? section.line.startPosition;
  }

  bool get _inSideline => _current?.model?.analysisPath.isNotEmpty ?? false;

  // ── Navigation ─────────────────────────────────────────────────────────

  /// Park the cursor after [index] mainline moves of [section].
  void _goTo(int section, int index) {
    final target = _sections[section];
    final model = target.model;
    if (model != null && !model.goToMainLineMove(index)) return;
    setState(() => _active = section);
    _scrollIntoView(atStart: index == 0 || model == null);
  }

  void _goToNode(int section, MoveNode node, int branchPly) {
    final model = _sections[section].model;
    if (model == null || !model.goToAnalysisNode(node, branchPly)) return;
    setState(() => _active = section);
    _scrollIntoView();
  }

  /// Ply to land on when moving from section [from] to section [to]: the
  /// first move of [to] that differs from [from], so the reader sees what is
  /// new rather than the shared opening again.
  int _divergencePly(int from, int to) {
    final a = _sections[from].sans;
    final b = _sections[to].sans;
    var i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    return (i + 1).clamp(0, _sections[to].length);
  }

  void _forward() {
    final section = _current;
    if (section == null) return;
    final model = section.model;
    if (model == null) {
      _nextLine();
      return;
    }
    if (model.analysisPath.isNotEmpty) {
      final last = model.analysisPath.last;
      if (last.children.isNotEmpty) {
        _goToNode(_active, last.children.first, model.activeBranchPly);
      }
      return;
    }
    if (model.mainLineIndex < model.moveHistory.length) {
      _goTo(_active, model.mainLineIndex + 1);
    } else {
      _nextLine();
    }
  }

  void _back() {
    final section = _current;
    if (section == null) return;
    final model = section.model;
    if (model == null) {
      _previousLine();
      return;
    }
    if (model.analysisPath.isNotEmpty) {
      final path = model.analysisPath;
      if (path.length == 1) {
        _goTo(_active, model.activeBranchPly);
      } else {
        _goToNode(_active, path[path.length - 2], model.activeBranchPly);
      }
      return;
    }
    if (model.mainLineIndex > 0) {
      _goTo(_active, model.mainLineIndex - 1);
    } else if (_active > 0) {
      // Start of the line: back into the end of the previous one.
      _goTo(_active - 1, _sections[_active - 1].length);
    }
  }

  void _nextLine() {
    if (_active + 1 >= _sections.length) return;
    _goTo(_active + 1, _divergencePly(_active, _active + 1));
  }

  void _previousLine() {
    if (_active == 0) return;
    _goTo(_active - 1, _divergencePly(_active, _active - 1));
  }

  void _returnToMainline() {
    final model = _current?.model;
    if (model == null || model.analysisPath.isEmpty) return;
    _goTo(_active, model.activeBranchPly);
  }

  /// Keep the cursor on screen. The book is a lazy list, so a section far
  /// from the viewport may not be built yet; in that case jump near it and
  /// try once more after the frame.
  void _scrollIntoView({bool atStart = false, bool retried = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sections.isEmpty) return;
      final key = atStart ? _sections[_active].headingKey : _currentMoveKey;
      final ctx = key.currentContext;
      if (ctx == null) {
        if (retried || !_scroll.hasClients) return;
        final fraction = _active / _sections.length;
        _scroll.jumpTo(fraction * _scroll.position.maxScrollExtent);
        _scrollIntoView(atStart: atStart, retried: true);
        return;
      }
      final renderObject = ctx.findRenderObject();
      final scrollable = Scrollable.maybeOf(ctx);
      if (renderObject == null || scrollable == null) return;
      unawaited(
        scrollable.position.ensureVisible(
          renderObject,
          alignment: atStart ? 0.05 : 0.35,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        ),
      );
    });
  }

  // ── Handoffs ───────────────────────────────────────────────────────────

  void _train(RepertoireLine line) {
    final handoff = widget.onTrainLine;
    if (handoff == null) return;
    Navigator.of(context).pop();
    handoff(line);
  }

  void _edit(RepertoireLine line) {
    final handoff = widget.onEditLine;
    if (handoff == null) return;
    Navigator.of(context).pop();
    handoff(line);
  }

  // ── Keys ───────────────────────────────────────────────────────────────

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) =>
      handleKeyBindings(_keyBindings, event, node: node);

  List<KeyBinding> get _keyBindings => [
    ...KeyBinding.forShortcut(
      AppShortcut.backOneMove,
      'Back one move',
      _back,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.forwardOneMove,
      'Forward one move',
      _forward,
      repeats: true,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.goToStart,
      'Start of this line',
      () => _goTo(_active, 0),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.goToEnd,
      'End of this line',
      () => _goTo(_active, _sections[_active].length),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.previousItem,
      'Previous line',
      _previousLine,
    ),
    ...KeyBinding.forShortcut(AppShortcut.nextItem, 'Next line', _nextLine),
    ...KeyBinding.forShortcut(
      AppShortcut.returnToMainline,
      'Return to mainline',
      _returnToMainline,
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.flipBoard,
      'Flip board',
      () => setState(() => _flipped = !_flipped),
    ),
    ...KeyBinding.forShortcut(
      AppShortcut.leave,
      'Close',
      () => Navigator.of(context).maybePop(),
    ),
  ];

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return TrainerKeyboardScope(
      onKeyEvent: _onKeyEvent,
      holdsFocus: true,
      focusNode: _focusNode,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Text(
            '${widget.repertoireName} ▸ ${widget.chapterTitle}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          actions: [
            IconButton(
              tooltip: actionTooltip('Close', shortcut: AppShortcut.leave),
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        body: _sections.isEmpty
            ? const Center(
                child: Text(
                  'Nothing to read here yet.',
                  style: TextStyle(color: AppColors.onSurfaceMuted),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  // Prose needs the wider column; the board only needs to
                  // be square. Stack them when there is no room for both.
                  if (constraints.maxWidth < 760) {
                    return Column(
                      children: [
                        SizedBox(
                          height: constraints.maxHeight * 0.5,
                          child: _buildBoardPane(compact: true),
                        ),
                        const Divider(height: 1),
                        Expanded(child: _buildBook()),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 5, child: _buildBoardPane()),
                      const VerticalDivider(width: 1),
                      Expanded(flex: 6, child: _buildBook()),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _buildBoardPane({bool compact = false}) {
    final section = _current!;
    final line = section.line;
    final status = lineStatusOf(widget.reviewMap[line.id]);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.all(compact ? 8 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  position: _position,
                  enableUserMoves: false,
                  flipped: _flipped,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _navButton(
                icon: Icons.first_page,
                description: 'Start of this line',
                shortcut: AppShortcut.goToStart,
                onPressed: () => _goTo(_active, 0),
              ),
              _navButton(
                icon: Icons.chevron_left,
                description: 'Back one move',
                shortcut: AppShortcut.backOneMove,
                onPressed: _back,
              ),
              _navButton(
                icon: Icons.chevron_right,
                description: 'Forward one move',
                shortcut: AppShortcut.forwardOneMove,
                onPressed: _forward,
              ),
              _navButton(
                icon: Icons.last_page,
                description: 'End of this line',
                shortcut: AppShortcut.goToEnd,
                onPressed: () => _goTo(_active, section.length),
              ),
              const SizedBox(width: 12),
              _navButton(
                icon: Icons.swap_vert,
                description: 'Flip board',
                shortcut: AppShortcut.flipBoard,
                onPressed: () => setState(() => _flipped = !_flipped),
              ),
            ],
          ),
          if (_inSideline)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Center(
                child: TextButton.icon(
                  onPressed: _returnToMainline,
                  icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
                  label: Text(
                    actionTooltip(
                      'Return to mainline',
                      shortcut: AppShortcut.returnToMainline,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.onSurfaceSoft,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
          if (!compact) ...[
            const SizedBox(height: 12),
            Text(
              'Line ${_active + 1} of ${_sections.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              line.name,
              style: theme.textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              line.isModelGame ? 'Model game' : status.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.onTrainLine != null && !line.isModelGame)
                  FilledButton.icon(
                    onPressed: () => _train(line),
                    icon: const Icon(Icons.school_outlined, size: 16),
                    label: const Text('Train this line'),
                  ),
                if (widget.onEditLine != null)
                  TextButton.icon(
                    onPressed: () => _edit(line),
                    icon: const Icon(Icons.edit, size: 16),
                    label: Text(widget.editLabel),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _navButton({
    required IconData icon,
    required String description,
    required AppShortcut shortcut,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: actionTooltip(description, shortcut: shortcut),
      icon: Icon(icon),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildBook() {
    // SelectionArea lets the user drag-select prose and copy it; move taps
    // still reach the chips underneath.
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 48),
        itemCount: _sections.length,
        itemBuilder: _buildSection,
      ),
    );
  }

  Widget _buildSection(BuildContext context, int index) {
    final section = _sections[index];
    final line = section.line;
    final model = section.model;
    final active = index == _active;
    final theme = Theme.of(context);
    final status = lineStatusOf(widget.reviewMap[line.id]);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: active ? AppColors.onSurfaceSoft : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              key: section.headingKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        line.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: active ? null : AppColors.onSurfaceSoft,
                        ),
                      ),
                      Text(
                        line.isModelGame ? 'Model game' : status.label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.onTrainLine != null && !line.isModelGame)
                  TextButton.icon(
                    onPressed: () => _train(line),
                    icon: const Icon(Icons.school_outlined, size: 16),
                    label: const Text('Train'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.onSurfaceSoft,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (model == null)
              Text(
                'Could not read this line\'s PGN: ${section.parseError}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceMuted,
                ),
              )
            else
              PgnMovetextView(
                game: model.game,
                moveHistory: model.moveHistory,
                variationsByPly: model.variationsByPly,
                // Only the section under the cursor shows a current move;
                // the others read as plain text until clicked.
                mainLineIndex: active ? model.mainLineIndex : 0,
                analysisPath: active ? model.analysisPath : const [],
                editingCommentIndex: null,
                canEditComments: false,
                startingMoveNumber: model.startPosition.fullmoves,
                startingWhiteTurn: model.startPosition.turn == Side.white,
                startPosition: model.startPosition,
                currentMoveKey: active ? _currentMoveKey : null,
                onMainLineMoveClicked: (moveIndex) =>
                    _goTo(index, moveIndex + 1),
                onShowMoveContextMenu: (_, _) {},
                onSaveComment: (_, _) {},
                onCancelEditingComment: () {},
                onGoToAnalysisNode: (node, branchPly) =>
                    _goToNode(index, node, branchPly),
              ),
          ],
        ),
      ),
    );
  }
}
