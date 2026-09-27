import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../chess_core/moves/move_tree_view.dart';
import '../../chess_core/moves/sideline_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart' show coordsAtPly;
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';
import 'pgn_reading_scroll.dart';

/// A sideline is identified by its actual first move, including for games
/// starting from a FEN. No generated chapter names or separate variation index.
class PgnReadingBranch {
  final MoveNodeView root;
  final int ply;
  final int branchPly;
  final MoveNodeView? parent;
  const PgnReadingBranch(this.root, this.ply, this.branchPly, this.parent);
}

typedef PgnDocumentBuilder =
    Widget Function(
      GlobalKey currentMoveKey,
      PgnReadingBranch? scope,
      bool expandAll,
      PgnReadingViewport viewport,
    );

/// Reading policy supplied to the document's bounded viewport. The pane owns
/// the scroll controller and exact anchor; the renderer owns row identity.
class PgnReadingViewport {
  const PgnReadingViewport({
    required this.controller,
    required this.padding,
    required this.revision,
    required this.foldRevision,
    required this.onAnchorChanged,
    this.restoreAnchor,
  });
  final ScrollController controller;
  final EdgeInsets padding;
  final int revision;
  final int foldRevision;
  final ValueChanged<Object?> onAnchorChanged;
  final Object? restoreAnchor;
}

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
  final List<MoveNodeView> analysisPath;
  final Map<int, List<MoveNodeView>> variationsByPly;
  final int branchPly;
  final int startingMoveNumber;
  final bool startingWhiteTurn;
  final VoidCallback onMainline;
  final void Function(MoveNodeView, int) onNode;
  final PgnDocumentBuilder documentBuilder;

  const PgnReadingPane({
    super.key,
    required this.selection,
    this.backgroundColor = AppColors.pgnSurface,
    this.showReadingOptions = true,
    this.continuationPicker,
    this.previewingComment = false,
    required this.analysisPath,
    required this.variationsByPly,
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
  final _bookmarks =
      <({PgnReadingBranch? scope, double offset, Object? anchor})>[];
  Object? _documentAnchor;
  Object? _restoreAnchor;
  PgnReadingBranch? _scope;
  bool _expandAll = false;
  int _foldRevision = 0;
  bool _browsing = false;
  double _anchor = 0;
  double? _restoreOffset;
  int _scrollRequest = 0;

  double get readingAnchor => _anchor;

  void applyReadingOption(String value) => _applyReadingOption(value);

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
        if (i == 0 || path[i - 1].children.firstOrNull?.id != path[i].id)
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
    if (!identical(oldWidget.variationsByPly, widget.variationsByPly)) {
      _scope = _refreshBranch(_scope);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        _bookmarks[i] = (
          scope: _refreshBranch(bookmark.scope),
          offset: bookmark.offset,
          anchor: bookmark.anchor,
        );
      }
    }
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

  PgnReadingBranch? _refreshBranch(PgnReadingBranch? branch) {
    if (branch == null) return null;
    final path = widget.variationsByPly.pathToNode(
      branch.root,
      branchPly: branch.branchPly,
    );
    if (path == null) return null;
    return PgnReadingBranch(
      path.last,
      branch.branchPly + path.length - 1,
      branch.branchPly,
      path.length > 1 ? path[path.length - 2] : null,
    );
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
    _restoreAnchor = null;
    if (restore != null) return restore;
    final target = _currentMove.currentContext?.findRenderObject();
    if (target == null) return 0;
    // Resolve against this viewport only; ancestor TabBarViews must not move.
    final viewport = RenderAbstractViewport.of(target);
    // Only the origin is needed. The viewport mounts a selected row on its
    // forward sliver before requesting an anchor, so this transform never
    // needs a reverse-sliver child's height during ancestor layout.
    final top =
        MatrixUtils.transformPoint(
          target.getTransformTo(viewport),
          Offset.zero,
        ).dy +
        (viewport as RenderViewport).offset.pixels;
    final inset = _anchor == 0 ? 52.0 : viewportDimension * _anchor;
    // A centered sliver viewport permits offset zero even when its trailing
    // half is shorter than the viewport. Clamp to the document end as well,
    // so a final move cannot leave an otherwise avoidable empty page below it.
    final end = viewport.lastChild!.geometry!.scrollExtent - viewportDimension;
    return top - inset < end ? top - inset : end;
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
      _bookmarks.add((
        scope: _scope,
        offset: _scroll.offset,
        anchor: _documentAnchor,
      ));
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
          _restoreAnchor = bookmark.anchor;
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
            final inset = constraints.maxWidth >= 700 ? 32.0 : 24.0;
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
                      child: PgnReadingAnchorLayout(
                        revision: _scrollRequest,
                        child: widget.documentBuilder(
                          _currentMove,
                          _scope,
                          _expandAll,
                          PgnReadingViewport(
                            controller: _scroll,
                            revision: _scrollRequest,
                            foldRevision: _foldRevision,
                            padding: EdgeInsets.fromLTRB(
                              inset,
                              32,
                              inset,
                              floatingHeight == 0 ? 32 : floatingHeight + 24,
                            ),
                            restoreAnchor: _restoreAnchor,
                            onAnchorChanged: (key) => _documentAnchor = key,
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
