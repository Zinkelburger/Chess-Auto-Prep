import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../layout/repertoire_mode.dart';
import '../navigation_trail.dart';

/// Tab bar, navigation trail, and tab views for the repertoire right pane.
class RepertoireTabBar extends StatelessWidget {
  const RepertoireTabBar({
    super.key,
    required this.tabController,
    required this.navigationStack,
    required this.onNavigationJump,
    required this.tabChildren,
    this.mode = RepertoireMode.edit,
    this.isCompactLayout = false,
  });

  final TabController tabController;
  final NavigationStack navigationStack;
  final void Function(NavigationEntry entry) onNavigationJump;
  final List<Widget> tabChildren;
  final RepertoireMode mode;

  /// Below [kCompactBreakpoint]: Edit uses PGN + Context tabs; Analyze uses one tab.
  final bool isCompactLayout;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          NavigationTrail(
            stack: navigationStack,
            onJumpTo: onNavigationJump,
          ),
          TabBar(
            controller: tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: _tabsForMode(mode, isCompactLayout),
          ),
          Expanded(
            child: TabBarView(
              controller: tabController,
              children: [
                for (final child in tabChildren)
                  _KeepAliveTab(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static List<Tab> _tabsForMode(RepertoireMode mode, bool isCompactLayout) {
    if (mode == RepertoireMode.analyze) {
      return [
        Tab(
          text: isCompactLayout ? 'Analysis' : 'Lines',
          icon: Icon(
            isCompactLayout ? Icons.analytics_outlined : Icons.library_books,
            size: 16,
          ),
        ),
      ];
    }

    if (isCompactLayout) {
      return const [
        Tab(
          text: 'PGN',
          icon: Icon(Icons.description, size: 16),
        ),
        Tab(
          text: 'Context',
          icon: Icon(Icons.dashboard_customize_outlined, size: 16),
        ),
      ];
    }

    return const [
      Tab(
        text: 'Browse',
        icon: Icon(Icons.explore, size: 16),
      ),
      Tab(
        text: 'PGN',
        icon: Icon(Icons.description, size: 16),
      ),
    ];
  }
}

/// Wraps a child widget so [TabBarView] keeps it alive when off-screen.
class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
