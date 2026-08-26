/// Resizable, collapsible bottom pane with tabbed content (VS Code-style).
///
/// Tabs: Findings, Jobs. Collapsed by default; opens to a specific
/// tab when triggered. Drag-resizable top edge. Full-width under both
/// board and right pane columns.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'bottom_pane_controller.dart';

export 'bottom_pane_controller.dart' show BottomPaneController, BottomPaneTab;

class BottomPane extends StatefulWidget {
  /// Open/closed state and active tab, owned by the screen.
  final BottomPaneController controller;

  final Widget findingsContent;
  final Widget jobsContent;

  final int findingsBadge;
  final int jobsBadge;

  /// Called when the pane is closed via the X button or drag-handle double-tap.
  /// Not called for programmatic [BottomPaneState.close] — callers of that
  /// method handle their own cleanup.
  final VoidCallback? onClose;

  const BottomPane({
    super.key,
    required this.controller,
    required this.findingsContent,
    required this.jobsContent,
    this.findingsBadge = 0,
    this.jobsBadge = 0,
    this.onClose,
  });

  @override
  State<BottomPane> createState() => BottomPaneState();
}

class BottomPaneState extends State<BottomPane>
    with SingleTickerProviderStateMixin {
  static const double _dragHandleHeight = 6.0;
  static const double _tabBarHeight = 32.0;

  late final TabController _tabController;

  BottomPaneController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: BottomPaneTab.values.length,
      vsync: this,
      initialIndex: _controller.activeTab.index,
    );
    _controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant BottomPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// Mirror the controller's tab onto the TabController, which owns the
  /// indicator animation, then rebuild for collapsed/height changes.
  void _onControllerChanged() {
    if (!mounted) return;
    final index = _controller.activeTab.index;
    if (_tabController.index != index) _tabController.animateTo(index);
    setState(() {});
  }

  void _closeFromChrome() {
    _controller.close();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isCollapsed) return const SizedBox.shrink();

    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = screenHeight * BottomPaneController.maxHeightFraction;
    final desiredHeight = screenHeight * _controller.heightFraction;
    final clampedHeight = desiredHeight.clamp(
      BottomPaneController.minHeightPx,
      maxHeight,
    );

    return SizedBox(
      height: clampedHeight,
      child: Column(
        children: [
          _buildDragHandle(context, maxHeight),
          _buildTabBar(context),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [widget.findingsContent, widget.jobsContent],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDragHandle(BuildContext context, double maxHeight) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        final currentPx = screenHeight * _controller.heightFraction;
        final newPx = (currentPx - details.delta.dy).clamp(
          BottomPaneController.minHeightPx,
          maxHeight,
        );
        _controller.setHeightFraction(
          screenHeight > 0
              ? newPx / screenHeight
              : BottomPaneController.defaultHeightFraction,
        );
      },
      onDoubleTap: _closeFromChrome,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: _dragHandleHeight,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Center(
            child: Container(
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: _tabBarHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: _tabController,
              onTap: (i) => _controller.open(BottomPaneTab.values[i]),
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              indicatorSize: TabBarIndicatorSize.label,
              dividerHeight: 0,
              labelStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 11),
              tabs: [
                _buildTab('Findings', widget.findingsBadge, AppColors.warning),
                _buildTab('Jobs', widget.jobsBadge, AppColors.accent),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            onPressed: _closeFromChrome,
            tooltip: 'Collapse (Esc)',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildTab(String label, int badge, Color? badgeColor) {
    return Tab(
      height: _tabBarHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (badge > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: (badgeColor ?? AppColors.onSurfaceMuted).withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$badge',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: badgeColor ?? AppColors.onSurfaceMuted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
