part of 'pgn_movetext_view.dart';

/// Deepest sideline level rendered unconditionally. Alternatives that would
/// land deeper are folded behind a "▸ N more lines" stub the reader can open.
/// Machine-generated repertoire trees routinely nest far past anything a human
/// wants to read in one pass; without a fold they bury the mainline.
const _kAlwaysVisibleDepth = 2;

/// A single, unannotated alternative this many plies long is faster to read in
/// place than as a separate block. Anything longer, commented, or branching
/// gets the full-width treatment below. Four plies is enough to answer the
/// common "instead of this, play that" question without creating a paragraph
/// inside the mainline.
const _kMaxInlineVariationPlies = 4;

/// Build a compact parenthesized alternative, or return null when the line
/// deserves its own indented block.
///
/// Parentheses therefore carry one precise meaning in the viewer: a brief
/// aside. Structural variations use whitespace + a gutter instead, which
/// avoids the wall of nested brackets found in raw PGN dumps.
List<InlineSpan>? _buildInlineVariationAtPly(
  PgnMovetextView view,
  int ply, {
  bool Function(MoveNode node)? nodeVisible,
}) {
  var roots = view.variationsByPly[ply];
  if (roots == null || roots.length != 1) return null;

  var node = roots.single;
  if (nodeVisible != null && !nodeVisible(node)) return null;

  final line = <MoveNode>[];
  while (true) {
    if (node.comment?.trim().isNotEmpty ?? false) return null;
    line.add(node);
    if (line.length > _kMaxInlineVariationPlies) return null;

    final visibleChildren = nodeVisible == null
        ? node.children
        : node.children.where(nodeVisible).toList();
    if (visibleChildren.isEmpty) break;
    if (visibleChildren.length != 1) return null;
    node = visibleChildren.single;
  }

  final spans = <InlineSpan>[
    TextSpan(text: '(', style: PgnTextStyles.parenthesisAt(1)),
  ];
  var coords = _coordsAtPly(view, ply);
  for (var i = 0; i < line.length; i++) {
    if (coords.isWhite) {
      spans.add(
        TextSpan(
          text: '${coords.moveNumber}. ',
          style: PgnTextStyles.moveNumberAt(1),
        ),
      );
    } else if (i == 0) {
      spans.add(
        TextSpan(
          text: '${coords.moveNumber}... ',
          style: PgnTextStyles.moveNumberAt(1),
        ),
      );
    }
    spans.add(_variationMoveSpan(view, line[i], 1, ply));
    if (i < line.length - 1) spans.add(const TextSpan(text: ' '));
    coords = (
      moveNumber: coords.isWhite ? coords.moveNumber : coords.moveNumber + 1,
      isWhite: !coords.isWhite,
    );
  }
  spans.add(TextSpan(text: ') ', style: PgnTextStyles.parenthesisAt(1)));
  return spans;
}

/// Render sidelines as ordinary paragraphs, with a foldable move label in
/// the gutter. Nesting changes structure, never the size of the explanation.
List<Widget> _buildVariationRowsAtPly(
  PgnMovetextView view,
  int ply, {
  bool Function(MoveNode node)? nodeVisible,
  required Map<int, bool> branchVisibility,
  required ValueChanged<int> onToggleBranch,
}) => [
  for (final root in view.variationsByPly[ply] ?? <MoveNode>[])
    if (nodeVisible == null || nodeVisible(root))
      _buildVariationDocument(
        view,
        root,
        ply: ply,
        branchPly: ply,
        depth: 1,
        branchVisibility: branchVisibility,
        onToggleBranch: onToggleBranch,
        nodeVisible: nodeVisible,
      ),
];

Widget _buildVariationDocument(
  PgnMovetextView view,
  MoveNode root, {
  required int ply,
  required int branchPly,
  required int depth,
  required Map<int, bool> branchVisibility,
  required ValueChanged<int> onToggleBranch,
  bool Function(MoveNode)? nodeVisible,
}) {
  final containsCurrent = view.analysisPath.any((n) => n.id == root.id);
  final defaultOpen = branchVisibility.putIfAbsent(
    root.id,
    () => view.expandAll || depth <= _kAlwaysVisibleDepth,
  );
  final open = depth == 0 || containsCurrent || defaultOpen;
  final coords = _coordsAtPly(view, ply);
  final label =
      '${coords.moveNumber}${coords.isWhite ? '.' : '...'} ${root.san}';
  final children = <Widget>[];
  final run = <InlineSpan>[];
  void flush() {
    if (run.isEmpty) return;
    children.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text.rich(
          TextSpan(
            style: PgnTextStyles.rowRootAt(depth),
            children: List.of(run),
          ),
        ),
      ),
    );
    run.clear();
  }

  if (open) {
    MoveNode? cursor = root;
    var index = ply;
    while (cursor != null) {
      final node = cursor;
      final pos = _coordsAtPly(view, index);
      final comment = node.comment;
      final rendered = comment == null
          ? (block: null, spans: <InlineSpan>[])
          : _renderComment(
              view,
              comment,
              anchorPos: node.positionOrNull,
              anchorPly: index + 1,
              interactive: false,
            );
      final metrics = comment == null
          ? <InlineSpan>[]
          : _metricsSpans(comment, depth: depth);
      final annotated = rendered.block != null || rendered.spans.isNotEmpty;
      if (annotated) flush();
      final passageStart = children.length;
      if (!isNullMoveSan(node.san)) {
        if (pos.isWhite || run.isEmpty) {
          run.add(
            TextSpan(
              text: '${pos.moveNumber}${pos.isWhite ? '.' : '...'} ',
              style: PgnTextStyles.moveNumberAt(depth),
            ),
          );
        }
        run.add(
          _variationMoveSpan(
            view,
            node,
            depth,
            branchPly,
            attachKey: !annotated,
          ),
        );
        run.add(const TextSpan(text: ' '));
      }
      if (metrics.isNotEmpty) {
        flush();
        children.add(Text.rich(TextSpan(children: metrics)));
      }
      if (annotated) {
        flush();
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 15),
            child:
                rendered.block ??
                Text.rich(
                  TextSpan(
                    style: PgnTextStyles.commentAt(depth),
                    children: rendered.spans,
                  ),
                ),
          ),
        );
        final passage = children.sublist(passageStart);
        children.removeRange(passageStart, children.length);
        children.add(
          PgnReadingPassage(
            key: view.analysisPath.lastOrNull?.id == node.id
                ? view.currentMoveKey
                : null,
            active: view.analysisPath.lastOrNull?.id == node.id,
            children: passage,
          ),
        );
      }
      final next = nodeVisible == null
          ? node.children
          : node.children.where(nodeVisible).toList();
      if (next.length > 1) {
        flush();
        for (final alternative in next.skip(1)) {
          children.add(
            _buildVariationDocument(
              view,
              alternative,
              ply: index + 1,
              branchPly: branchPly,
              depth: depth + 1,
              branchVisibility: branchVisibility,
              onToggleBranch: onToggleBranch,
              nodeVisible: nodeVisible,
            ),
          );
        }
      }
      cursor = next.firstOrNull;
      index++;
    }
    flush();
  }

  final content = Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (depth > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('pgn-branch-${root.id}'),
            onPressed: containsCurrent ? null : () => onToggleBranch(root.id),
            icon: Icon(
              open ? Icons.expand_more : Icons.chevron_right,
              size: 16,
            ),
            label: Text(label, style: PgnTextStyles.collapsedStub),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
          ),
        ),
      ...children,
    ],
  );
  if (depth == 0) return content;
  return Container(
    margin: EdgeInsets.only(
      left: depth <= PgnTextStyles.maxStyledDepth ? 5 : 0,
      top: 16,
      bottom: 22,
    ),
    padding: EdgeInsets.only(
      left: depth <= PgnTextStyles.maxStyledDepth ? 17 : 0,
    ),
    decoration: BoxDecoration(
      border: depth <= PgnTextStyles.maxStyledDepth
          ? const Border(left: BorderSide(color: AppColors.pgnVariationRule))
          : null,
    ),
    child: content,
  );
}

/// A tappable SAN chip inside a sideline row.
InlineSpan _variationMoveSpan(
  PgnMovetextView view,
  MoveNode node,
  int depth,
  int branchPly, {
  bool attachKey = true,
}) {
  final isCurrentNode =
      view.analysisPath.isNotEmpty && view.analysisPath.last.id == node.id;

  // Every NAG, same as the mainline — a sideline's `⩲` is the reason the
  // sideline is there.
  final nagSuffix = allNagSuffix(node.nags);

  final base = PgnTextStyles.moveAt(
    depth,
    ephemeral: node.isEphemeral,
    quiet: attachKey,
  );
  final sanStyle = isCurrentNode
      ? base.copyWith(color: AppColors.pgnMoveCurrentFg)
      : base;
  final currentDecoration = BoxDecoration(
    color: node.isEphemeral
        ? AppColors.pgnEphemeralBg
        : AppColors.pgnMoveCurrentBg,
    borderRadius: BorderRadius.circular(3),
    border: Border.all(color: Colors.transparent, width: 1),
  );

  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: MoveChip(
      containerKey: isCurrentNode && attachKey ? view.currentMoveKey : null,
      san: node.san,
      nagSuffix: nagSuffix,
      sanStyle: sanStyle,
      nagStyle: sanStyle.copyWith(
        fontSize: PgnTextStyles.sizeAt(depth) - 1,
        fontWeight: FontWeight.bold,
      ),
      decoration: isCurrentNode ? currentDecoration : _kReservedBorder,
      hoverDecoration: isCurrentNode ? currentDecoration : _kHoverDecoration,
      behavior: HitTestBehavior.opaque,
      onTap: () => view.onGoToAnalysisNode(node, branchPly),
      onSecondaryTapDown: view.onShowVariationContextMenu != null
          ? (details) => view.onShowVariationContextMenu!(
              node,
              branchPly,
              details.globalPosition,
            )
          : null,
    ),
  );
}
