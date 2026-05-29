import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../navigation_trail.dart';

/// Tab bar and tab views for the compact repertoire right pane (PGN | Context).
class RepertoireTabBar extends StatelessWidget {
  const RepertoireTabBar({
    super.key,
    required this.tabController,
    required this.navigationStack,
    required this.onNavigationJump,
    required this.tabChildren,
    this.isCompactLayout = true,
  });

  final TabController tabController;
  final NavigationStack navigationStack;
  final void Function(NavigationEntry entry) onNavigationJump;
  final List<Widget> tabChildren;

  /// Below [kCompactBreakpoint]: PGN + Context tabs.
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
            tabs: _tabsForCompact(isCompactLayout),
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

  static List<Tab> _tabsForCompact(bool isCompactLayout) {
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
