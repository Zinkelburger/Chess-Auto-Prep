/// Tabbed underboard panel below the board row.
///
/// Houses Jobs and Findings tabs (background task output only).
/// Resizable via drag handle, collapsible via tab click or keyboard shortcut.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double kUnderboardMinHeight = 80;
const double kUnderboardDefaultHeight = 180;
const double kUnderboardMaxHeight = 500;
const double kDragHandleHeight = 28;
const String _kHeightPrefKey = 'underboard_height';

/// Which underboard tab is active.
enum UnderboardTab { jobs, findings }

class UnderboardPanel extends StatefulWidget {
  final Widget jobsContent;
  final Widget findingsContent;

  /// Externally-driven tab selection (e.g. from status bar badge click).
  final UnderboardTab? requestedTab;

  /// Badge counts displayed on tab labels.
  final int findingsCount;
  final String? jobsStatus;

  /// Called when the active tab changes.
  final ValueChanged<UnderboardTab>? onTabChanged;

  const UnderboardPanel({
    super.key,
    required this.jobsContent,
    required this.findingsContent,
    this.requestedTab,
    this.findingsCount = 0,
    this.jobsStatus,
    this.onTabChanged,
  });

  @override
  State<UnderboardPanel> createState() => UnderboardPanelState();
}

class UnderboardPanelState extends State<UnderboardPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  double _panelHeight = kUnderboardDefaultHeight;
  bool _collapsed = true;
  bool _resizing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: UnderboardTab.values.length,
      vsync: this,
      initialIndex: widget.requestedTab?.index ?? 0,
    );
    _tabController.addListener(_onTabChanged);
    _loadHeight();
  }

  @override
  void didUpdateWidget(covariant UnderboardPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestedTab != null &&
        widget.requestedTab != oldWidget.requestedTab &&
        widget.requestedTab!.index != _tabController.index) {
      _tabController.animateTo(widget.requestedTab!.index);
      if (_collapsed) setState(() => _collapsed = false);
    }
  }

  void _onTabChanged() {
    widget.onTabChanged
        ?.call(UnderboardTab.values[_tabController.index]);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void openTab(UnderboardTab tab) {
    _tabController.animateTo(tab.index);
    if (_collapsed) setState(() => _collapsed = false);
  }

  void toggle() => setState(() => _collapsed = !_collapsed);

  bool get isCollapsed => _collapsed;

  Future<void> _loadHeight() async {
    final prefs = await SharedPreferences.getInstance();
    final h = prefs.getDouble(_kHeightPrefKey);
    if (h != null && mounted) setState(() => _panelHeight = h);
  }

  Future<void> _saveHeight() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kHeightPrefKey, _panelHeight);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTabBar(theme),
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: _collapsed ? 0 : _panelHeight,
          curve: Curves.easeOut,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: _collapsed
              ? const SizedBox.shrink()
              : TabBarView(
                  controller: _tabController,
                  children: [
                    widget.jobsContent,
                    widget.findingsContent,
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildTabBar(ThemeData theme) {
    return GestureDetector(
      onVerticalDragStart: (_) => _resizing = true,
      onVerticalDragUpdate: (d) {
        if (!_resizing) return;
        setState(() {
          _panelHeight = (_panelHeight - d.delta.dy)
              .clamp(kUnderboardMinHeight, kUnderboardMaxHeight);
          if (_collapsed) _collapsed = false;
        });
      },
      onVerticalDragEnd: (_) {
        _resizing = false;
        _saveHeight();
      },
      onDoubleTap: toggle,
      child: Container(
        height: kDragHandleHeight,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          border: Border(
            top: BorderSide(color: theme.dividerColor),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.zero,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                indicatorSize: TabBarIndicatorSize.label,
                dividerHeight: 0,
                labelStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                unselectedLabelStyle: const TextStyle(fontSize: 12),
                tabs: [
                  _tabWithStatus('Jobs', widget.jobsStatus,
                      theme.colorScheme.primary),
                  _tabWithBadge('Findings', widget.findingsCount,
                      theme.colorScheme.error),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.drag_handle, size: 16, color: Colors.grey[600]),
            ),
            IconButton(
              icon: Icon(
                _collapsed
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
              ),
              onPressed: toggle,
              tooltip: _collapsed ? 'Expand (`)' : 'Collapse (`)',
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 28, minHeight: kDragHandleHeight),
            ),
          ],
        ),
      ),
    );
  }

  Tab _tabWithBadge(String label, int count, Color color) {
    return Tab(
      height: kDragHandleHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Tab _tabWithStatus(String label, String? status, Color color) {
    return Tab(
      height: kDragHandleHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (status != null) ...[
            const SizedBox(width: 4),
            Text(status, style: TextStyle(fontSize: 10, color: color)),
          ],
        ],
      ),
    );
  }
}
