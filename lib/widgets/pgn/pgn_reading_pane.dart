import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../models/move_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart' show coordsAtPly;
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';

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
  final Color backgroundColor;
  final bool showReadingOptions;

  /// Keep the quoted passage on screen while its moves play on the board.
  final bool previewingComment;
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
    this.backgroundColor = AppColors.pgnSurface,
    this.showReadingOptions = true,
    this.previewingComment = false,
    required this.analysisPath,
    required this.branchPly,
    required this.startingMoveNumber,
    required this.startingWhiteTurn,
    required this.onMainline,
    required this.onNode,
    required this.documentBuilder,
  });

  static Color surfaceOf(BuildContext context) =>
      context
          .findAncestorWidgetOfExactType<PgnReadingPane>()
          ?.backgroundColor ??
      AppColors.pgnSurface;

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

  void _applyReadingOption(String value) {
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
  }

  /// Hosts can place this action in their own settings menu.
  Future<void> showReadingOptions() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Move list'),
        children: [
          for (final option in const {
            '0': 'Anchor near top',
            '0.35': 'Anchor near middle',
            '0.68': 'Anchor near bottom',
            'expand': 'Expand all variations',
            'fold': 'Fold deep variations',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option.key),
              child: Text(option.value),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (mounted && value != null) _applyReadingOption(value);
  }

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
    if (oldWidget.selection != widget.selection && !widget.previewingComment) {
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

  bool focusVariation() {
    final branch = _branches.lastOrNull;
    if (!mounted || branch == null || branch.root.id == _scope?.root.id) {
      return false;
    }
    setState(() {
      _bookmarks.add((scope: _scope, offset: _scroll.offset));
      _scope = branch;
      _browsing = false;
    });
    _scheduleAnchor();
    return true;
  }

  /// Leaving a focused branch with Left restores its parent reading position.
  bool backOutOfFocus() {
    if (_scope?.root.id != widget.analysisPath.lastOrNull?.id ||
        _scope == null) {
      return false;
    }
    return returnToParent();
  }

  bool returnToParent() {
    final branch = _branches.lastOrNull ?? _scope;
    if (!mounted || branch == null) return false;
    setState(() {
      if (branch.root.id == _scope?.root.id) {
        if (_bookmarks.isNotEmpty) {
          final bookmark = _bookmarks.removeLast();
          _scope = bookmark.scope;
          _restoreOffset = bookmark.offset;
        } else {
          _scope = null;
        }
      }
      _browsing = false;
    });
    if (branch.parent case final parent?) {
      widget.onNode(parent, branch.branchPly);
    } else {
      widget.onMainline();
    }
    _scheduleAnchor();
    return true;
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
        color: widget.backgroundColor,
        border: Border.all(color: const Color(0xFF363B43)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: [
            if (widget.showReadingOptions || branches.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xFF363B43))),
                ),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (widget.previewingComment)
                      const Text('Comment preview', style: AppTextStyles.muted),
                    TextButton(
                      onPressed: branches.isEmpty && !widget.previewingComment
                          ? null
                          : _mainline,
                      child: const Tooltip(
                        message: 'Return to mainline',
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
                      ShortcutTooltip(
                        description: 'Return to parent line',
                        shortcut: AppShortcut.returnToParentLine,
                        child: TextButton.icon(
                          onPressed: returnToParent,
                          icon: const Icon(
                            Icons.subdirectory_arrow_left,
                            size: 18,
                          ),
                          label: const Text('Return to parent'),
                        ),
                      ),
                    if (branches.isNotEmpty &&
                        branches.last.root.id != _scope?.root.id)
                      ShortcutTooltip(
                        description: 'Read this variation at full width',
                        shortcut: AppShortcut.focusVariation,
                        child: TextButton.icon(
                          onPressed: focusVariation,
                          icon: const Icon(Icons.zoom_in, size: 18),
                          label: const Text('Focus variation'),
                        ),
                      ),
                    if (widget.showReadingOptions)
                      PopupMenuButton<String>(
                        tooltip: 'Reading options',
                        icon: const Icon(Icons.tune, size: 18),
                        onSelected: _applyReadingOption,
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
                              // Bound move anchoring to the real document. A
                              // viewport of trailing space lets even a short
                              // game scroll its title away to reveal nothing.
                              padding: EdgeInsets.fromLTRB(
                                inset,
                                32,
                                inset,
                                32,
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
