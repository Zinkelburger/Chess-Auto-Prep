import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../models/move_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart' show coordsAtPly;

/// A sideline is identified by its actual first move, including for games
/// starting from a FEN. No generated chapter names or separate variation index.
class PgnReadingBranch {
  final MoveNode root;
  final int ply;
  final int branchPly;
  final MoveNode? parent;
  const PgnReadingBranch(this.root, this.ply, this.branchPly, this.parent);
}

typedef PgnDocumentBuilder =
    Widget Function(
      GlobalKey currentMoveKey,
      PgnReadingBranch? scope,
      bool expandAll,
    );

/// Owns reading position independently of the board cursor. Browsing prose
/// never changes the board; only a navigation action requests an anchor.
class PgnReadingPane extends StatefulWidget {
  final Object selection;
  final List<MoveNode> analysisPath;
  final int branchPly;
  final int startingMoveNumber;
  final bool startingWhiteTurn;
  final VoidCallback onMainline;
  final void Function(MoveNode, int) onNode;
  final PgnDocumentBuilder documentBuilder;

  const PgnReadingPane({
    super.key,
    required this.selection,
    required this.analysisPath,
    required this.branchPly,
    required this.startingMoveNumber,
    required this.startingWhiteTurn,
    required this.onMainline,
    required this.onNode,
    required this.documentBuilder,
  });

  @override
  State<PgnReadingPane> createState() => PgnReadingPaneState();
}

class PgnReadingPaneState extends State<PgnReadingPane> {
  final _scroll = ScrollController();
  final _currentMove = GlobalKey();
  final _bookmarks = <({PgnReadingBranch? scope, double offset})>[];
  PgnReadingBranch? _scope;
  bool _expandAll = false;
  int _foldRevision = 0;
  bool _browsing = false;
  double _anchor = 0;
  double? _restoreOffset;
  int _scrollRequest = 0;

  List<PgnReadingBranch> get _branches {
    final path = widget.analysisPath;
    return [
      for (var i = 0; i < path.length; i++)
        if (i == 0 || path[i - 1].children.firstOrNull != path[i])
          PgnReadingBranch(
            path[i],
            widget.branchPly + i,
            widget.branchPly,
            i == 0 ? null : path[i - 1],
          ),
    ];
  }

  String _label(PgnReadingBranch branch) {
    final coords = coordsAtPly(
      ply: branch.ply,
      startFullmoves: widget.startingMoveNumber,
      startWhiteToMove: widget.startingWhiteTurn,
    );
    return '${coords.moveNumber}${coords.isWhite ? '.' : '...'} ${branch.root.san}';
  }

  @override
  void initState() {
    super.initState();
    _scheduleAnchor();
  }

  @override
  void didUpdateWidget(PgnReadingPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      if (_scope != null &&
          !widget.analysisPath.any((n) => n.id == _scope!.root.id)) {
        _scope = null;
        _bookmarks.clear();
      }
      _browsing = false;
      _scheduleAnchor();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleAnchor() {
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _scrollRequest || !_scroll.hasClients) return;
      final restore = _restoreOffset;
      _restoreOffset = null;
      if (restore != null) {
        _scroll.jumpTo(restore.clamp(0, _scroll.position.maxScrollExtent));
        return;
      }
      final target = _currentMove.currentContext?.findRenderObject();
      if (target == null) {
        _scroll.jumpTo(0);
        return;
      }
      // Resolve against this viewport only: ensureVisible on all ancestors
      // would also move the host's TabBarView when this reader is offstage.
      final viewport = RenderAbstractViewport.of(target);
      final top = viewport.getOffsetToReveal(target, 0).offset;
      final inset = _anchor == 0
          ? 52.0
          : _scroll.position.viewportDimension * _anchor;
      final offset = (top - inset).clamp(0.0, _scroll.position.maxScrollExtent);
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      unawaited(
        _scroll.animateTo(
          offset,
          duration: Duration(milliseconds: reduceMotion ? 1 : 180),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  /// Returns false when Escape has no reading action to perform, so the host
  /// can continue its existing mode/analysis escape handling.
  bool returnToMove() {
    if (!_browsing) return false;
    setState(() => _browsing = false);
    _scheduleAnchor();
    return true;
  }

  void focusVariation() {
    final branch = _branches.lastOrNull;
    if (branch == null || branch.root.id == _scope?.root.id) return;
    setState(() {
      _bookmarks.add((scope: _scope, offset: _scroll.offset));
      _scope = branch;
      _browsing = false;
    });
    _scheduleAnchor();
  }

  void returnToParent() {
    final branch = _scope ?? _branches.lastOrNull;
    if (branch == null) return;
    setState(() {
      if (_bookmarks.isNotEmpty) {
        final bookmark = _bookmarks.removeLast();
        _scope = bookmark.scope;
        _restoreOffset = bookmark.offset;
      } else {
        _scope = null;
      }
      _browsing = false;
    });
    if (branch.parent case final parent?) {
      widget.onNode(parent, branch.branchPly);
    } else {
      widget.onMainline();
    }
    _scheduleAnchor();
  }

  void _mainline() {
    setState(() {
      _scope = null;
      _bookmarks.clear();
      _browsing = false;
    });
    widget.onMainline();
    _scheduleAnchor();
  }

  @override
  Widget build(BuildContext context) {
    final branches = _branches;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.pgnSurface,
        border: Border.all(color: const Color(0xFF363B43)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF363B43))),
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 2,
                children: [
                  TextButton(
                    onPressed: branches.isEmpty ? null : _mainline,
                    child: const Tooltip(
                      message: 'Return to mainline (R)',
                      child: Text('Main line', style: AppTextStyles.muted),
                    ),
                  ),
                  for (final branch in branches) ...[
                    const Icon(Icons.chevron_right, size: 14),
                    TextButton(
                      onPressed: () =>
                          widget.onNode(branch.root, branch.branchPly),
                      child: Text(_label(branch), style: AppTextStyles.mono),
                    ),
                  ],
                  if (branches.isNotEmpty)
                    IconButton(
                      tooltip: 'Parent line (Ctrl+←)',
                      onPressed: returnToParent,
                      icon: const Icon(Icons.subdirectory_arrow_left, size: 18),
                    ),
                  if (branches.isNotEmpty &&
                      branches.last.root.id != _scope?.root.id)
                    TextButton(
                      onPressed: focusVariation,
                      child: const Tooltip(
                        message:
                            'Read this variation at full width (Ctrl+Enter)',
                        child: Text('Focus variation'),
                      ),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Reading options',
                    icon: const Icon(Icons.tune, size: 18),
                    onSelected: (value) {
                      setState(() {
                        if (value == 'expand') {
                          _foldRevision++;
                          _expandAll = true;
                        } else if (value == 'fold') {
                          _foldRevision++;
                          _expandAll = false;
                        } else {
                          _anchor = double.parse(value);
                        }
                        _browsing = false;
                      });
                      _scheduleAnchor();
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(
                        value: '0',
                        checked: _anchor == 0,
                        child: const Text('Anchor near top'),
                      ),
                      CheckedPopupMenuItem(
                        value: '0.35',
                        checked: _anchor == .35,
                        child: const Text('Anchor near middle'),
                      ),
                      CheckedPopupMenuItem(
                        value: '0.68',
                        checked: _anchor == .68,
                        child: const Text('Anchor near bottom'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'expand',
                        child: Text('Expand all variations'),
                      ),
                      const PopupMenuItem(
                        value: 'fold',
                        child: Text('Fold deep variations'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final inset = constraints.maxWidth >= 700 ? 45.0 : 32.0;
                  return Stack(
                    children: [
                      NotificationListener<UserScrollNotification>(
                        onNotification: (notification) {
                          if (notification.direction != ScrollDirection.idle &&
                              !_browsing) {
                            setState(() => _browsing = true);
                          }
                          return false;
                        },
                        child: SelectionArea(
                          child: Scrollbar(
                            controller: _scroll,
                            child: SingleChildScrollView(
                              key: const ValueKey('pgn-reading-scroll'),
                              controller: _scroll,
                              padding: EdgeInsets.fromLTRB(
                                inset,
                                32,
                                inset,
                                constraints.maxHeight,
                              ),
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 760,
                                  ),
                                  child: KeyedSubtree(
                                    key: ValueKey(_foldRevision),
                                    child: widget.documentBuilder(
                                      _currentMove,
                                      _scope,
                                      _expandAll,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_browsing)
                        Positioned(
                          bottom: 14,
                          right: 14,
                          child: FilledButton.tonalIcon(
                            onPressed: returnToMove,
                            icon: const Icon(Icons.my_location, size: 16),
                            label: const Text('Back to current move (Esc)'),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
