/// Movetext rendering for the PGN viewer.
///
/// Renders mainline and sideline moves as a continuous annotated document.
/// The host owns board navigation; this view owns disclosure state and keeps
/// every explanation in its original place in the PGN.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_game_view.dart';
import '../../utils/pgn_nags.dart';
import '../../features/documents/models/viewer_document_layout.dart';
import '../../design_system/layout/anchored_document_viewport.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';

import '../../chess_core/pgn/mainline_positions.dart';
import '../../features/documents/models/solitaire_reveal.dart';
import '../../chess_core/moves/move_tree_view.dart';
import 'package:chess_auto_prep/chess_core/analysis/move_eval.dart'
    show MoveClassification, classifyMove, cpToWinningChance, initialWinChance;
import 'pgn_text_styles.dart';
import 'comment_editor.dart';
import 'comment_diagram.dart';
import '../../utils/course_comment_spacing.dart';
import '../../utils/prose_comment_parser.dart';
import 'pgn_reading_pane.dart';
import 'pgn_reading_scroll.dart';
import 'pgn_reading_passage.dart';
import 'movetext_primitives.dart' show MoveChip, PgnMoveDecorations;
import '../../utils/chess_utils.dart'
    show coordsAtPly, formatEvalDisplay, isNullMoveSan;
import '../../utils/chessable_comment_format.dart'
    show RichSegment, RichSegmentType, hasChessableFormatting, parseRichComment;
import '../../utils/comment_move_tokens.dart'
    show
        CommentDiagram,
        CommentMove,
        CommentProse,
        CommentToken,
        kSanCorePattern,
        parseCommentTokens;
import '../../utils/move_metrics.dart' show MoveMetrics;
import '../../utils/pgn_comment_utils.dart'
    show
        commentProse,
        filterDisplayComment,
        joinComments,
        kMaxUnevaluatedPlies,
        parseEvalComment,
        parseMaiaComment,
        parsePvComment,
        stripEngineTokens,
        stripPgnTokens;

part 'pgn_movetext_prose_scan.dart';
part 'pgn_movetext_comments.dart';
part 'pgn_movetext_eval_notes.dart';
part 'pgn_movetext_variations.dart';

// Also used by the prose-preview chips in the comment renderer.
const _kReservedBorder = PgnMoveDecorations.idle;

class PgnMovetextView extends StatefulWidget {
  /// The parsed game (for game-level comments before any move).
  final PgnGameMetadata? game;
  final PgnReadingBranch? readingScope;
  final bool expandAll;
  final Widget? header;
  final PgnReadingViewport? viewport;

  /// Mainline moves in display order.
  final List<PgnMoveSnapshot> moveHistory;

  /// Shared owner memo; annotation-only revisions do not replay the game.
  final MainlinePositions? mainlinePositions;

  /// ply (0-based mainline index) -> root variation nodes branching there.
  final Map<int, List<MoveNodeView>> variationsByPly;

  /// 1-based index of the current mainline position (0 = start).
  final int mainLineIndex;

  /// Path into the current variation (empty = on the mainline).
  final List<MoveNodeView> analysisPath;

  /// Mainline index whose comment is being edited inline, or null.
  final int? editingCommentIndex;

  /// Whether comments can be edited (click a move to edit its comment).
  final bool canEditComments;

  /// Show every source branch separately while editing its annotations.
  final bool editMode;

  /// Force book-PGN comment formatting for ambiguous source material.
  /// Recognizable Chessable/Forward Chess markup and long multi-paragraph
  /// comments are detected automatically; this flag is only needed when a
  /// short export uses double spaces as paragraph breaks without markers.
  final bool bookFormatting;

  /// Starting fullmove number from the FEN (defaults to 1).
  final int startingMoveNumber;

  /// Whether it's white's turn at the start (from the FEN; defaults to true).
  final bool startingWhiteTurn;

  /// The game's starting position. When provided, moves written inside prose
  /// comments are detected and made clickable if they are *legal* from the
  /// comment's anchor position (played via [onPlayInlineLine]).
  final Position? startPosition;

  final ValueChanged<int> onMainLineMoveClicked;
  final void Function(int moveIndex, Offset globalPosition)
  onShowMoveContextMenu;
  final void Function(int moveIndex, String text) onSaveComment;
  final VoidCallback onCancelEditingComment;
  final void Function(MoveNodeView node, int branchPly) onGoToAnalysisNode;

  /// Right-click on a variation node (copy line / add to study / delete menu).
  final void Function(MoveNodeView node, int branchPly, Offset globalPosition)?
  onShowVariationContextMenu;

  /// What a running solitaire session lets the reader see: mainline moves
  /// past its frontier and sidelines it has not reached are not rendered.
  /// Null when no session is running.
  final SolitaireReveal? reveal;

  /// Attached to the current move or annotated passage, including sidelines.
  final Key? currentMoveKey;

  /// Preview an inline analysis line embedded in a comment: navigate the board
  /// through the run starting at [moveNumber]/[isWhite] and stop at
  /// [clickedIndex]. [sans] is the run's full move list. This does not modify
  /// the move tree — it just walks the board so the comment keeps its rendering.
  final void Function(
    int moveNumber,
    bool isWhite,
    List<String> sans,
    int clickedIndex, {
    String? anchorFen,
  })?
  onPlayInlineLine;

  /// The inline line currently being previewed (for in-place highlighting), or
  /// null. Matched against each rendered run by its first move + move list.
  final ({
    int firstMoveNumber,
    bool firstIsWhite,
    List<String> sans,
    int cursor,
    String? anchorFen,
  })?
  activeInlineLine;

  const PgnMovetextView({
    super.key,
    required this.game,
    this.readingScope,
    this.expandAll = false,
    this.header,
    this.viewport,
    required this.moveHistory,
    this.mainlinePositions,
    required this.variationsByPly,
    required this.mainLineIndex,
    required this.analysisPath,
    required this.editingCommentIndex,
    required this.canEditComments,
    this.editMode = false,
    this.bookFormatting = false,
    this.startingMoveNumber = 1,
    this.startingWhiteTurn = true,
    this.startPosition,
    required this.onMainLineMoveClicked,
    required this.onShowMoveContextMenu,
    required this.onSaveComment,
    required this.onCancelEditingComment,
    required this.onGoToAnalysisNode,
    this.onShowVariationContextMenu,
    this.reveal,
    this.currentMoveKey,
    this.onPlayInlineLine,
    this.activeInlineLine,
  });

  @override
  State<PgnMovetextView> createState() => _PgnMovetextViewState();
}

class _PgnMovetextViewState extends State<PgnMovetextView> {
  final Map<int, bool> _branchVisibility = {};
  final _selectionKey = GlobalKey();
  final _session = Object();
  final _commentDrafts = <Object, String>{};
  ViewerDocumentLayout? _layout;
  Object? _layoutInputs;
  Set<int> _selectedBranches = {};
  List<PgnMoveSnapshot>? _evaluatedHistory;
  bool? _evaluatedWhiteTurn;
  bool _machineAnnotated = false;
  Map<int, _EvalNote> _evalNotes = const {};
  Map<int, int> _engineRoots = const {};

  bool _visible(MoveNodeView node, int ply) =>
      widget.reveal?.isNodeVisible(node, ply) ?? true;
  bool _visibleComment(String raw) =>
      filterDisplayComment(raw).isNotEmpty ||
      MoveMetrics.parse(raw).summary.isNotEmpty;

  bool _inline(int ply) =>
      _engineRoots[ply] == null &&
      _inlineVariationNodes(
            widget,
            ply,
            nodeVisible: (n) => _visible(n, ply),
          ) !=
          null;

  ViewerDocumentLayout _documentLayout() {
    if (!identical(_evaluatedHistory, widget.moveHistory) ||
        _evaluatedWhiteTurn != widget.startingWhiteTurn) {
      _evaluatedHistory = widget.moveHistory;
      _evaluatedWhiteTurn = widget.startingWhiteTurn;
      _machineAnnotated = _isMachineAnnotated(widget.moveHistory);
      _evalNotes = _machineAnnotated ? _buildEvalNotes(widget) : const {};
    }
    final path = widget.analysisPath;
    final selected = <int>{
      for (var i = 0; i < path.length; i++)
        if (i == 0 || path[i - 1].children.firstOrNull?.id != path[i].id)
          path[i].id,
      if (widget.readingScope != null) widget.readingScope!.root.id,
    };
    final inputs = (
      widget.moveHistory,
      widget.variationsByPly,
      widget.game,
      widget.readingScope?.root,
      widget.reveal,
      widget.expandAll,
      widget.editMode,
      widget.editingCommentIndex,
      widget.startingWhiteTurn,
    );
    if (_layout != null &&
        inputs == _layoutInputs &&
        setEquals(selected, _selectedBranches)) {
      return _layout!;
    }
    _layoutInputs = inputs;
    _selectedBranches = selected;
    _engineRoots = {
      for (final entry in _evalNotes.entries)
        if (entry.value.pv.isNotEmpty &&
            widget.editingCommentIndex != entry.key)
          for (final root
              in (widget.variationsByPly[entry.key] ?? const <MoveNodeView>[])
                  .where(
                    (n) =>
                        n.san == entry.value.pv.first && _visible(n, entry.key),
                  )
                  .take(1))
            entry.key: root.id,
    };
    return _layout = ViewerDocumentLayout(
      moves: widget.moveHistory,
      variations: widget.variationsByPly,
      visible: _visible,
      proseReference: (n, ply) => _isRepeatedProseReference(widget, n, ply),
      inlineVariation: _inline,
      visibility: _branchVisibility,
      selectedPath: selected,
      expandAll: widget.expandAll,
      frontier: widget.reveal?.mainlinePly ?? widget.moveHistory.length,
      engineRoots: _engineRoots,
      scope: widget.readingScope?.root,
      scopePly: widget.readingScope?.ply ?? 0,
      scopeBranchPly: widget.readingScope?.branchPly ?? 0,
      editingCommentIndex: widget.editingCommentIndex,
      breaksMainline: (move, i) =>
          widget.editingCommentIndex == i ||
          _evalNotes.containsKey(i) ||
          (move.startingComments?.any(_visibleComment) ?? false) ||
          (move.comments?.any(
                (raw) =>
                    !(_machineAnnotated && _isEvalOnlyComment(raw)) &&
                    _visibleComment(raw),
              ) ??
              false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = _documentLayout();
    final selected = widget.analysisPath.lastOrNull;
    final selectedRow = selected == null
        ? layout.mainlineRow(widget.mainLineIndex - 1) ?? 0
        : layout.nodeRow(selected.id);
    final config = widget.viewport;
    return AnchoredDocumentViewport(
      rows: _ViewerRows(layout),
      session: (_session, widget.readingScope?.root.id),
      selection: config?.revision ?? (widget.mainLineIndex, selected?.id),
      selectedRow: selectedRow,
      selectionKey: widget.currentMoveKey is GlobalKey
          ? widget.currentMoveKey as GlobalKey
          : _selectionKey,
      controller: config?.controller,
      scrollViewKey: config == null
          ? null
          : const ValueKey('pgn-reading-scroll'),
      revealSelection: config == null,
      restoreAnchor: config?.restoreAnchor,
      onAnchorChanged: config?.onAnchorChanged,
      rowBuilder: (index) {
        final row = layout.rows[index];
        var child = switch (row) {
          ViewerIntroductionRow() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.header != null) widget.header!,
              _buildMainlineRange(context, 0, 0, introduction: true),
            ],
          ),
          ViewerMainlineRow() => _buildMainlineRange(
            context,
            row.start,
            row.end,
          ),
          ViewerVariationRow() => _buildVariationRow(
            context,
            widget,
            row,
            onToggleBranch: _toggleBranch,
          ),
          ViewerFrontierRow() => RichText(
            text: TextSpan(
              style: PgnTextStyles.rowRootAt(context, 0),
              children: _buildInlineVariationAtPly(
                context,
                widget,
                row.ply,
                nodeVisible: (n) => _visible(n, row.ply),
              ),
            ),
          ),
        };
        if (row is ViewerVariationRow && row.engineMove != null) {
          final note = _evalNotes[row.engineMove]!;
          final continues =
              index + 1 < layout.rows.length &&
              layout.rows[index + 1] is ViewerVariationRow &&
              (layout.rows[index + 1] as ViewerVariationRow).engineMove ==
                  row.engineMove;
          child = Container(
            key: ValueKey((
              'pgn-analysis-variation',
              row.engineMove,
              row.nodes.first.id,
            )),
            margin: EdgeInsets.fromLTRB(20, 0, 0, continues ? 0 : 14),
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: PgnTextStyles.nagInk(
                    context,
                    note.classification.nag ?? 0,
                  ).withValues(alpha: .55),
                  width: 2,
                ),
              ),
            ),
            child: child,
          );
        }
        final padding = config?.padding ?? EdgeInsets.zero;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            index == 0 ? padding.top : 0,
            padding.right,
            index == layout.rows.length - 1 ? padding.bottom : 0,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: PgnReadingAnchorLayout(
                revision: config?.revision ?? 0,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggleBranch(int id) {
    if (!mounted) return;
    setState(() {
      _branchVisibility[id] =
          !(_branchVisibility[id] ??
              (widget.expandAll ||
                  (_layout?.rows
                              .whereType<ViewerVariationRow>()
                              .where((r) => r.root.id == id)
                              .firstOrNull
                              ?.depth ??
                          1) <=
                      2));
      _layout = null;
    });
  }

  @override
  void didUpdateWidget(PgnMovetextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editingCommentIndex != widget.editingCommentIndex ||
        oldWidget.moveHistory.firstOrNull?.identity !=
            widget.moveHistory.firstOrNull?.identity) {
      _commentDrafts.clear();
    }
    if (oldWidget.expandAll != widget.expandAll ||
        oldWidget.viewport?.foldRevision != widget.viewport?.foldRevision ||
        oldWidget.game != widget.game) {
      _branchVisibility.clear();
      _layout = null;
    }
  }

  Widget _buildMainlineRange(
    BuildContext context,
    int start,
    int end, {
    bool introduction = false,
  }) {
    final view = widget;
    final children = <Widget>[];
    final spans = <InlineSpan>[];
    final coords = _coordsAtPly(view, start);
    var moveNumber = coords.moveNumber;
    var isWhiteTurn = coords.isWhite;
    // After a comment/variation/editor breaks the mainline Wrap run, the next
    // Black move must show `N...` (same as the start-of-game Black case).
    var forceBlackEllipsis = start > 0;

    // Root style for RichText runs of mainline moves; comments/variations
    // use their own styles via [PgnTextStyles].
    final baseStyle = PgnTextStyles.rowRootAt(context, 0);

    void flushSpans() {
      if (spans.isNotEmpty) {
        children.add(
          RichText(
            text: TextSpan(style: baseStyle, children: List.of(spans)),
          ),
        );
        spans.clear();
        forceBlackEllipsis = true;
      }
    }

    /// Put [child] on its own full-width row so Wrap cannot glue it into
    /// neighboring move spans (anti-spaghetti for comments / variations).
    void emitFullWidthRow(Widget child, {double vertical = 4}) {
      flushSpans();
      forceBlackEllipsis = true;
      children.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: vertical),
          child: SizedBox(width: double.infinity, child: child),
        ),
      );
    }

    void emitComment(String raw, {Position? anchorPos, int anchorPly = 0}) {
      // Measured facts first, on their own row: a generated line annotates
      // every move, and interleaving that with prose would bury both.
      final metrics = _metricsSpans(context, raw);
      if (metrics.isNotEmpty) {
        emitFullWidthRow(
          RichText(text: TextSpan(children: List.of(metrics))),
          vertical: 2,
        );
      }
      final rendered = _renderComment(
        context,
        view,
        raw,
        anchorPos: anchorPos,
        anchorPly: anchorPly,
      );
      if (rendered.block != null) {
        // Blocks already carry their own vertical margin — don't double it.
        emitFullWidthRow(_readableProse(rendered.block!), vertical: 0);
      } else if (rendered.spans.isNotEmpty) {
        emitFullWidthRow(
          _readableProse(
            RichText(
              text: TextSpan(
                style: PgnTextStyles.commentAt(context, 0),
                children: List.of(rendered.spans),
              ),
            ),
          ),
        );
      }
    }

    void emitEvalNote(_EvalNote note, int moveIndex) {
      emitFullWidthRow(
        Container(
          margin: EdgeInsets.fromLTRB(
            20,
            6,
            0,
            _engineRoots[moveIndex] == null ? 14 : 0,
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: PgnTextStyles.nagInk(
                  context,
                  note.classification.nag ?? 0,
                ).withValues(alpha: 0.55),
                width: 2,
              ),
            ),
          ),
          child: Column(
            key: ValueKey('pgn-analysis-line-$moveIndex'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RichText(
                text: TextSpan(
                  style: PgnTextStyles.commentAt(context, 0),
                  children: _evalNoteSpans(context, note),
                ),
              ),
            ],
          ),
        ),
        vertical: 0,
      );
    }

    void emitVariationsAtPly(int ply) {
      if (!_inline(ply)) return;
      spans.addAll(
        _buildInlineVariationAtPly(
          context,
          view,
          ply,
          nodeVisible: (n) => _visible(n, ply),
        )!,
      );
    }

    // Board after each mainline half-move (prefix[k] = position after k moves),
    // used to legality-check moves mentioned inside prose comments.
    final prefix = _buildPrefixPositions(view);

    // On a game an engine has been over, the per-ply `[%eval]` comments are
    // not rendered at all — every classified move gets a mark, including
    // interesting moves identified by Maia. A game with no mistakes in it still hides them, which is why this
    // is a separate flag and not "are there any notes".
    final machineAnnotated = _machineAnnotated;
    final evalNotes = _evalNotes;

    // Game-level comments (before any moves) — common in book PGNs
    if (introduction && view.game != null && view.game!.comments.isNotEmpty) {
      for (final comment in view.game!.comments) {
        emitComment(comment, anchorPos: _posAt(prefix, 0), anchorPly: 0);
      }
    }

    for (int i = start; i < end; i++) {
      // Solitaire mode: stop rendering at the revealed boundary
      if (view.reveal != null && !view.reveal!.isMainlineVisible(i)) break;

      final moveData = view.moveHistory[i];
      final san = moveData.san;
      final annotated = (moveData.comments ?? const <String>[]).any(
        (c) => filterDisplayComment(c).isNotEmpty,
      );
      if (annotated) flushSpans();

      // Render startingComments (comments before the move)
      if (moveData.startingComments != null &&
          moveData.startingComments!.isNotEmpty) {
        for (final sc in moveData.startingComments!) {
          emitComment(sc, anchorPos: _posAt(prefix, i), anchorPly: i);
        }
      }

      final passageStart = children.length;

      // Skip rendering null-move SAN (ChessBase `--` / `Z0`) but still show
      // comments and any sidelines that branch after the pass.
      if (isNullMoveSan(san)) {
        for (final c in moveData.comments ?? const <String>[]) {
          if (machineAnnotated && _isEvalOnlyComment(c)) continue;
          emitComment(c, anchorPos: _posAt(prefix, i), anchorPly: i);
        }
        final ply = i;
        final varsHere = view.variationsByPly[ply];
        if (varsHere != null && varsHere.isNotEmpty) {
          emitVariationsAtPly(ply);
        }
        if (!isWhiteTurn) moveNumber++;
        isWhiteTurn = !isWhiteTurn;
        continue;
      }

      if (isWhiteTurn) {
        spans.add(
          TextSpan(
            text: '$moveNumber. ',
            style: PgnTextStyles.moveNumberAt(context, 0),
          ),
        );
        forceBlackEllipsis = false;
      } else if (forceBlackEllipsis || (i == 0 && !view.startingWhiteTurn)) {
        // Black after a line break (comment/variation/editor) or game start.
        spans.add(
          TextSpan(
            text: '$moveNumber... ',
            style: PgnTextStyles.moveNumberAt(context, 0),
          ),
        );
        forceBlackEllipsis = false;
      }

      final isCurrentMove =
          i == view.mainLineIndex - 1 &&
          view.analysisPath.isEmpty &&
          view.activeInlineLine == null;

      // SAN styling is independent of NAGs and of whether a sideline exists —
      // structure (own-row, indented variations) marks branches, not a hue.
      // The current move keeps the mainline's weight and size; only the pill
      // changes, so navigating never reflows the wrapped movetext.
      final moveStyle = isCurrentMove
          ? PgnTextStyles.moveAt(
              context,
              0,
            ).copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer)
          : PgnTextStyles.moveAt(context, 0);

      // Build SAN + NAG text (always shown — annotations survive view mode).
      // Every NAG, not just the six editable quality glyphs: `⩲`, `∞`, `→` and
      // friends are the annotator's whole verdict on the position.
      // Cached games may predate persisted quality NAGs. Show the same
      // symbols immediately from their scores, without rewriting on read.
      final nags =
          evalNotes[i]?.classification.annotateNags(moveData.nags) ??
          moveData.nags;
      final nagSuffix = allNagSuffix(nags);

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MoveChip(
            san: san,
            nagSuffix: nagSuffix,
            sanStyle: moveStyle,
            nagStyle: PgnTextStyles.nagAt(
              context,
              0,
              moveStyle: moveStyle,
              nags: nags,
            ),
            decoration: PgnMoveDecorations.resolve(
              context,
              selected: isCurrentMove,
            ),
            hoverDecoration: PgnMoveDecorations.resolve(
              context,
              selected: isCurrentMove,
              hovered: true,
            ),
            containerKey: isCurrentMove && !annotated
                ? view.currentMoveKey
                : null,
            behavior: HitTestBehavior.opaque,
            onTap: () => view.onMainLineMoveClicked(i),
            onSecondaryTapDown: (details) =>
                view.onShowMoveContextMenu(i, details.globalPosition),
          ),
        ),
      );

      spans.add(const TextSpan(text: ' '));

      // Inline comment editor
      if (view.editingCommentIndex == i) {
        flushSpans();
        forceBlackEllipsis = true;
        children.add(
          PgnCommentEditor(
            key: ValueKey(moveData.identity),
            initialText:
                _commentDrafts[moveData.identity] ??
                commentProse(_rawComment(moveData)),
            onChanged: (text) => _commentDrafts[moveData.identity] = text,
            onSave: (text) {
              if (!mounted) return;
              _commentDrafts.remove(moveData.identity);
              view.onSaveComment(i, text);
            },
            onCancel: () {
              if (!mounted) return;
              _commentDrafts.remove(moveData.identity);
              view.onCancelEditingComment();
            },
          ),
        );
      } else {
        final note = evalNotes[i];

        // All of them. A PGN may attach several `{}` blocks to one move (a
        // Lichess study export splits prose from a `[%cal]` block, book PGNs
        // split a header from its text); showing only the first quietly hid
        // whichever half came second. The exception is a bare engine score on
        // an analyzed game: [evalNotes] already says everything it had to say.
        for (final c in moveData.comments ?? const <String>[]) {
          if (machineAnnotated && _isEvalOnlyComment(c)) continue;
          emitComment(c, anchorPos: _posAt(prefix, i + 1), anchorPly: i + 1);
        }

        if (note != null) emitEvalNote(note, i);
      }

      if (annotated) {
        flushSpans();
        final passage = children.sublist(passageStart);
        children.removeRange(passageStart, children.length);
        children.add(
          PgnReadingPassage(
            key: isCurrentMove ? view.currentMoveKey : null,
            active: isCurrentMove,
            children: passage,
          ),
        );
      }

      // RAVs at i are alternatives to the move just read, so its explanation
      // comes first (including opening comments before root alternatives).
      emitVariationsAtPly(i);

      if (!isWhiteTurn) moveNumber++;
      isWhiteTurn = !isWhiteTurn;
    }

    flushSpans();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

final class _ViewerRows implements DocumentRows {
  const _ViewerRows(this.layout);
  final ViewerDocumentLayout layout;
  @override
  Object get revision => layout;
  @override
  int get length => layout.rows.length;
  @override
  Object keyAt(int index) => layout.rows[index].key;
  @override
  int? indexOfKey(Object key) => layout.indexOfKey(key);
}
