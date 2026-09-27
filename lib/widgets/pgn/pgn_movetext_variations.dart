part of 'pgn_movetext_view.dart';

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
  BuildContext context,
  PgnMovetextView view,
  int ply, {
  bool Function(MoveNodeView node)? nodeVisible,
}) {
  final line = _inlineVariationNodes(view, ply, nodeVisible: nodeVisible);
  if (line == null) return null;
  final spans = <InlineSpan>[
    TextSpan(text: '(', style: PgnTextStyles.parenthesisAt(context, 1)),
  ];
  var coords = _coordsAtPly(view, ply);
  for (var i = 0; i < line.length; i++) {
    if (coords.isWhite) {
      spans.add(
        TextSpan(
          text: '${coords.moveNumber}. ',
          style: PgnTextStyles.moveNumberAt(context, 1),
        ),
      );
    } else if (i == 0) {
      spans.add(
        TextSpan(
          text: '${coords.moveNumber}... ',
          style: PgnTextStyles.moveNumberAt(context, 1),
        ),
      );
    }
    spans.add(_variationMoveSpan(context, view, line[i], 1, ply));
    if (i < line.length - 1) spans.add(const TextSpan(text: ' '));
    coords = (
      moveNumber: coords.isWhite ? coords.moveNumber : coords.moveNumber + 1,
      isWhite: !coords.isWhite,
    );
  }
  spans.add(
    TextSpan(text: ') ', style: PgnTextStyles.parenthesisAt(context, 1)),
  );
  return spans;
}

List<MoveNodeView>? _inlineVariationNodes(
  PgnMovetextView view,
  int ply, {
  bool Function(MoveNodeView)? nodeVisible,
}) {
  var roots = view.variationsByPly[ply];
  if (roots == null || roots.length != 1) return null;

  var node = roots.single;
  if (nodeVisible != null && !nodeVisible(node)) return null;

  final line = <MoveNodeView>[];
  while (true) {
    if ((node.comment?.trim().isNotEmpty ?? false) ||
        (node.startingComment?.trim().isNotEmpty ?? false)) {
      return null;
    }
    line.add(node);
    if (line.length > _kMaxInlineVariationPlies) return null;

    final visibleChildren = nodeVisible == null
        ? node.children
        : node.children.where(nodeVisible).toList();
    if (visibleChildren.isEmpty) break;
    if (visibleChildren.length != 1) return null;
    node = visibleChildren.single;
  }

  return line;
}

// Course exporters encode clickable mentions as duplicate one-move RAVs.
// Keep the nodes intact, but read a leaf repeating the principal move as prose.
// Editing, NAGs, scratch analysis and actual continuations retain their rows.
bool _isRepeatedProseReference(
  PgnMovetextView view,
  MoveNodeView node,
  int ply,
) =>
    !view.editMode &&
    !node.isEphemeral &&
    node.children.isEmpty &&
    (node.nags?.isEmpty ?? true) &&
    (node.startingComment?.trim().isEmpty ?? true) &&
    MoveMetrics.parse(node.comment ?? '').summary.isEmpty &&
    ply < view.moveHistory.length &&
    node.san == view.moveHistory[ply].san &&
    filterDisplayComment(node.comment ?? '').isNotEmpty;

Widget _buildProseReference(
  BuildContext context,
  PgnMovetextView view,
  MoveNodeView node,
  int ply,
) {
  final coords = _coordsAtPly(view, ply);
  final rendered = _renderProseComment(
    context,
    view,
    '${coords.moveNumber}${coords.isWhite ? '.' : '...'}${node.san} ${node.comment}',
    anchorPos: _posAt(_buildPrefixPositions(view), ply),
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: rendered.block ?? Text.rich(TextSpan(children: rendered.spans)),
  );
}

Widget _buildVariationRow(
  BuildContext context,
  PgnMovetextView view,
  ViewerVariationRow row, {
  required ValueChanged<int> onToggleBranch,
}) {
  if (row.proseReference) {
    return _buildProseReference(context, view, row.root, row.ply);
  }
  final root = row.root;
  final ply = row.ply;
  final branchPly = row.branchPly;
  final depth = row.depth;
  final containsCurrent = row.containsCurrent;
  final open = row.open;
  final leadingLabel = row.engineMove != null && row.first && depth == 1
      ? 'Best: '
      : null;
  final coords = _coordsAtPly(view, ply);
  final label =
      '${coords.moveNumber}${coords.isWhite ? '.' : '...'} ${root.san}';
  final children = <Widget>[];
  final indent = depth > 0 && depth <= PgnTextStyles.maxStyledDepth
      ? 24.0
      : 0.0;
  Widget disclosure() => SizedBox(
    width: 24,
    height: 28,
    child: IconButton(
      key: ValueKey('pgn-branch-${root.id}'),
      tooltip: containsCurrent
          ? 'Current variation: $label'
          : '${open ? 'Collapse' : 'Expand'} variation: $label',
      onPressed: containsCurrent ? null : () => onToggleBranch(root.id),
      padding: EdgeInsets.zero,
      iconSize: 18,
      icon: Icon(open ? Icons.expand_more : Icons.chevron_right),
    ),
  );
  Widget moveRow(Widget text, {required bool first}) => first && depth > 0
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            disclosure(),
            Expanded(child: text),
          ],
        )
      : Padding(
          padding: EdgeInsets.only(left: indent),
          child: text,
        );
  var firstRun = row.first;
  final run = <InlineSpan>[
    if (leadingLabel != null)
      TextSpan(
        text: leadingLabel,
        style: PgnTextStyles.metricsAt(context, depth),
      ),
  ];
  void flush() {
    if (run.isEmpty) return;
    children.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: moveRow(
          Text.rich(
            TextSpan(
              style: PgnTextStyles.rowRootAt(context, depth),
              children: List.of(run),
            ),
          ),
          first: firstRun,
        ),
      ),
    );
    firstRun = false;
    run.clear();
  }

  if (open) {
    var index = ply;
    for (final node in row.nodes) {
      final introduction = node.startingComment;
      if (introduction != null && introduction.trim().isNotEmpty) {
        flush();
        final prose = _renderComment(
          context,
          view,
          introduction,
          anchorPly: index,
          interactive: false,
        );
        if (prose.block != null || prose.spans.isNotEmpty) {
          children.add(
            Padding(
              padding: EdgeInsets.only(left: indent),
              child: _readableProse(
                prose.block ??
                    Text.rich(
                      TextSpan(
                        style: PgnTextStyles.commentAt(context, depth),
                        children: prose.spans,
                      ),
                    ),
              ),
            ),
          );
        }
      }
      final pos = _coordsAtPly(view, index);
      final comment = node.comment;
      final rendered = comment == null
          ? (block: null, spans: <InlineSpan>[])
          : _renderComment(
              context,
              view,
              comment,
              anchorPos: node.positionOrNull,
              anchorPly: index + 1,
              interactive: false,
            );
      final metrics = comment == null
          ? <InlineSpan>[]
          : _metricsSpans(context, comment, depth: depth);
      final annotated = rendered.block != null || rendered.spans.isNotEmpty;
      if (annotated) flush();
      final passageStart = children.length;
      if (!isNullMoveSan(node.san)) {
        if (pos.isWhite || run.isEmpty || index == ply) {
          run.add(
            TextSpan(
              text: '${pos.moveNumber}${pos.isWhite ? '.' : '...'} ',
              style: PgnTextStyles.moveNumberAt(context, depth),
            ),
          );
        }
        run.add(
          _variationMoveSpan(
            context,
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
        children.add(
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: Text.rich(TextSpan(children: metrics)),
          ),
        );
      }
      if (annotated) {
        flush();
        children.add(
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: _readableProse(
              rendered.block ??
                  Text.rich(
                    TextSpan(
                      style: PgnTextStyles.commentAt(context, depth),
                      children: rendered.spans,
                    ),
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
      index++;
    }
    flush();
  }

  final content = Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: open
        ? children
        : [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: moveRow(
                Text.rich(
                  TextSpan(
                    children: [
                      if (leadingLabel != null)
                        TextSpan(
                          text: leadingLabel,
                          style: PgnTextStyles.metricsAt(context, depth),
                        ),
                      TextSpan(
                        text:
                            '${coords.moveNumber}${coords.isWhite ? '.' : '...'} ',
                        style: PgnTextStyles.moveNumberAt(context, depth),
                      ),
                      TextSpan(
                        text: root.san,
                        style: PgnTextStyles.moveAt(context, depth),
                      ),
                      if (allNagSuffix(root.nags).isNotEmpty)
                        TextSpan(
                          text: allNagSuffix(root.nags),
                          style: PgnTextStyles.nagAt(
                            context,
                            depth,
                            moveStyle: PgnTextStyles.moveAt(context, depth),
                            nags: root.nags,
                          ),
                        ),
                    ],
                  ),
                ),
                first: true,
              ),
            ),
          ],
  );
  final ancestorIndent =
      (depth - 1).clamp(0, PgnTextStyles.maxStyledDepth) * 24.0;
  return Padding(
    padding: EdgeInsets.only(
      left: ancestorIndent,
      top: depth > 0 && row.first ? 6 : 0,
      bottom: depth > 0 ? 8 : 0,
    ),
    child: content,
  );
}

/// A tappable SAN chip inside a sideline row.
InlineSpan _variationMoveSpan(
  BuildContext context,
  PgnMovetextView view,
  MoveNodeView node,
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
    context,
    depth,
    ephemeral: node.isEphemeral,
  );
  final sanStyle = isCurrentNode
      ? base.copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer)
      : base;

  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: MoveChip(
      containerKey: isCurrentNode && attachKey ? view.currentMoveKey : null,
      san: node.san,
      nagSuffix: nagSuffix,
      sanStyle: sanStyle,
      nagStyle: PgnTextStyles.nagAt(
        context,
        depth,
        moveStyle: sanStyle,
        nags: node.nags,
      ),
      decoration: PgnMoveDecorations.resolve(context, selected: isCurrentNode),
      hoverDecoration: PgnMoveDecorations.resolve(
        context,
        selected: isCurrentNode,
        hovered: true,
      ),
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
