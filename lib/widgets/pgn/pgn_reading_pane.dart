import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../models/move_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart' show coordsAtPly;
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';
import 'pgn_reading_scroll.dart';

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

  /// Floating continuation choices, absent at positions without a fork.
  final Widget? continuationPicker;

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
    this.continuationPicker,
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
  late final _scroll = PgnReadingScrollController(
    resolveAnchor: _resolveAnchor,
  );
  var _currentMove = GlobalKey();
  final _bookmarks = <({PgnReadingBranch? scope, double offset})>[];
  PgnReadingBranch? _scope;
  bool _expandAll = false;
  int _foldRevision = 0;
  bool _browsing = false;
  double _anchor = 0;
  double? _restoreOffset;
  int _scrollRequest = 0;

  void _applyReadingOption(String value) {
    if (!mounted) return;
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
    // A previous move can remain in the inactive element list until after
    // layout. Resolve only a key attached by the new document build.
    _currentMove = GlobalKey();
    _scrollRequest++;
    _scroll.requestAnchor();
  }

  double _resolveAnchor(double viewportDimension) {
    final restore = _restoreOffset;
    _restoreOffset = null;
    if (restore != null) return restore;
    final target = _currentMove.currentContext?.findRenderObject();
    if (target == null) return 0;
    // Resolve against this viewport only; ancestor TabBarViews must not move.
    final viewport = RenderAbstractViewport.of(target);
    // Only the origin is needed. Reading descendant paint bounds during
    // viewport layout would access a size outside its permitted layout scope.
    final top = viewport.getOffsetToReveal(target, 0, rect: Rect.zero).offset;
    final inset = _anchor == 0 ? 52.0 : viewportDimension * _anchor;
    return top - inset;
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
    if (!mounted) return;
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
    final showToolbar =
        branches.isNotEmpty ||
        widget.previewingComment ||
        widget.showReadingOptions;
    final floatingRows = [
      if (_browsing) 40.0,
      if (showToolbar) 48.0,
      if (widget.continuationPicker != null) 44.0,
    ];
    final floatingHeight =
        floatingRows.fold(0.0, (sum, height) => sum + height) +
        (floatingRows.length > 1 ? (floatingRows.length - 1) * 8 : 0);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        border: Border.all(color: const Color(0xFF363B43)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = constraints.maxWidth >= 700 ? 45.0 : 32.0;
            return Stack(
              fit: StackFit.expand,
              children: [
                NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (!mounted) return false;
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
                        // Only add clearance for controls that are visible.
                        // This keeps the document end reachable beneath the
                        // overlay without reserving a row in the viewport.
                        padding: EdgeInsets.fromLTRB(
                          inset,
                          32,
                          inset,
                          floatingHeight == 0 ? 32 : floatingHeight + 24,
                        ),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: PgnReadingAnchorLayout(
                              revision: _scrollRequest,
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
                ),
                if (floatingHeight > 0)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    right: 8,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 8,
                      children: [
                        if (_browsing)
                          Align(
                            alignment: Alignment.centerRight,
                            child: SizedBox(
                              height: 40,
                              child: FilledButton.tonalIcon(
                                onPressed: returnToMove,
                                icon: const Icon(Icons.my_location, size: 16),
                                label: const Text('Back to current move (Esc)'),
                              ),
                            ),
                          ),
                        if (showToolbar)
                          Material(
                            elevation: 4,
                            color: AppColors.surfaceElevated,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: AppColors.divider),
                            ),
                            child: SizedBox(
                              height: 48,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 0,
                                ),
                                // Keep the toolbar to one row, including on nested lines.
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: 48,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      spacing: 10,
                                      children: [
                                        if (widget.previewingComment)
                                          const Text(
                                            'Comment preview',
                                            style: AppTextStyles.muted,
                                          ),
                                        if (branches.isNotEmpty ||
                                            widget.previewingComment)
                                          TextButton(
                                            onPressed: _mainline,
                                            child: const Tooltip(
                                              message: 'Return to mainline',
                                              child: Text(
                                                'Back to game',
                                                style: AppTextStyles.muted,
                                              ),
                                            ),
                                          ),
                                        for (final branch in branches) ...[
                                          const Icon(
                                            Icons.chevron_right,
                                            size: 14,
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              if (!mounted) return;
                                              widget.onNode(
                                                branch.root,
                                                branch.branchPly,
                                              );
                                            },
                                            child: Text(
                                              _label(branch),
                                              style: AppTextStyles.mono,
                                            ),
                                          ),
                                        ],
                                        if (branches.isNotEmpty)
                                          ShortcutTooltip(
                                            description:
                                                'Return to parent line',
                                            shortcut:
                                                AppShortcut.returnToParentLine,
                                            child: TextButton.icon(
                                              onPressed: returnToParent,
                                              icon: const Icon(
                                                Icons.subdirectory_arrow_left,
                                                size: 18,
                                              ),
                                              label: const Text(
                                                'Return to parent',
                                              ),
                                            ),
                                          ),
                                        if (branches.isNotEmpty &&
                                            branches.last.root.id !=
                                                _scope?.root.id)
                                          ShortcutTooltip(
                                            description:
                                                'Read this variation at full width',
                                            shortcut:
                                                AppShortcut.focusVariation,
                                            child: TextButton.icon(
                                              onPressed: focusVariation,
                                              icon: const Icon(
                                                Icons.zoom_in,
                                                size: 18,
                                              ),
                                              label: const Text(
                                                'Focus variation',
                                              ),
                                            ),
                                          ),
                                        if (widget.showReadingOptions)
                                          PopupMenuButton<String>(
                                            tooltip: 'Reading options',
                                            icon: const Icon(
                                              Icons.tune,
                                              size: 18,
                                            ),
                                            onSelected: _applyReadingOption,
                                            itemBuilder: (_) => [
                                              CheckedPopupMenuItem(
                                                value: '0',
                                                checked: _anchor == 0,
                                                child: const Text(
                                                  'Anchor near top',
                                                ),
                                              ),
                                              CheckedPopupMenuItem(
                                                value: '0.35',
                                                checked: _anchor == .35,
                                                child: const Text(
                                                  'Anchor near middle',
                                                ),
                                              ),
                                              CheckedPopupMenuItem(
                                                value: '0.68',
                                                checked: _anchor == .68,
                                                child: const Text(
                                                  'Anchor near bottom',
                                                ),
                                              ),
                                              const PopupMenuDivider(),
                                              const PopupMenuItem(
                                                value: 'expand',
                                                child: Text(
                                                  'Expand all variations',
                                                ),
                                              ),
                                              const PopupMenuItem(
                                                value: 'fold',
                                                child: Text(
                                                  'Fold deep variations',
                                                ),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (widget.continuationPicker case final picker?)
                          Material(
                            elevation: 4,
                            color: AppColors.surfaceElevated,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: AppColors.divider),
                            ),
                            child: SizedBox(height: 44, child: picker),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
