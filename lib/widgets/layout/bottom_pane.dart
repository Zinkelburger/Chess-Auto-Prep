/// Resizable, collapsible bottom pane with tabbed content (VS Code-style).
///
/// Tabs: Findings, Jobs, Lines. Collapsed by default; opens to a specific
/// tab when triggered. Drag-resizable top edge. Full-width under both
/// board and right pane columns.
library;

import 'package:flutter/material.dart';

enum BottomPaneTab { findings, jobs, lines }

class BottomPane extends StatefulWidget {
  final Widget findingsContent;
  final Widget jobsContent;
  final Widget linesContent;

  final int findingsBadge;
  final int jobsBadge;
  final int linesBadge;

  const BottomPane({
    super.key,
    required this.findingsContent,
    required this.jobsContent,
    required this.linesContent,
    this.findingsBadge = 0,
    this.jobsBadge = 0,
    this.linesBadge = 0,
  });

  @override
  State<BottomPane> createState() => BottomPaneState();
}

class BottomPaneState extends State<BottomPane>
    with SingleTickerProviderStateMixin {
  static const double _minHeight = 120.0;
  static const double _maxFraction = 0.60;
  static const double _defaultFraction = 0.45;
  static const double _dragHandleHeight = 6.0;
  static const double _tabBarHeight = 32.0;

  late final TabController _tabController;

  bool _collapsed = true;
  double? _height;

  bool get isCollapsed => _collapsed;
  BottomPaneTab get activeTab => BottomPaneTab.values[_tabController.index];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void open(BottomPaneTab tab) {
    setState(() {
      _collapsed = false;
      _tabController.animateTo(tab.index);
    });
  }

  void close() {
    setState(() => _collapsed = true);
  }

  void toggle([BottomPaneTab? tab]) {
    if (_collapsed) {
      open(tab ?? BottomPaneTab.values[_tabController.index]);
    } else if (tab != null && _tabController.index != tab.index) {
      _tabController.animateTo(tab.index);
    } else {
      close();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_collapsed) return const SizedBox.shrink();

    final screenHeight = MediaQuery.of(context).size.height;
    final maxHeight = screenHeight * _maxFraction;
    _height ??= screenHeight * _defaultFraction;
    final clampedHeight = _height!.clamp(_minHeight, maxHeight);

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
              children: [
                widget.findingsContent,
                widget.jobsContent,
                widget.linesContent,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDragHandle(BuildContext context, double maxHeight) {
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        setState(() {
          _height = ((_height ?? maxHeight * 0.5) - details.delta.dy)
              .clamp(_minHeight, maxHeight);
        });
      },
      onDoubleTap: close,
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
        border: Border(
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              indicatorSize: TabBarIndicatorSize.label,
              dividerHeight: 0,
              labelStyle: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 11),
              tabs: [
                _buildTab('Findings', widget.findingsBadge, Colors.orange),
                _buildTab('Jobs', widget.jobsBadge, Colors.teal),
                _buildTab('Lines', widget.linesBadge, null),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            onPressed: close,
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
                color: (badgeColor ?? Colors.grey).withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$badge',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: badgeColor ?? Colors.grey,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
