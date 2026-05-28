import 'package:flutter/material.dart';

import '../../services/navigation_stack.dart';
import '../navigation_trail.dart';

/// Tab bar, navigation trail, and tab views for the repertoire right pane.
class RepertoireTabBar extends StatelessWidget {
  const RepertoireTabBar({
    super.key,
    required this.tabController,
    required this.navigationStack,
    required this.isGenerating,
    required this.isGenerationPaused,
    required this.onNavigationJump,
    required this.tabChildren,
  });

  final TabController tabController;
  final NavigationStack navigationStack;
  final bool isGenerating;
  final bool isGenerationPaused;
  final void Function(NavigationEntry entry) onNavigationJump;
  final List<Widget> tabChildren;

  @override
  Widget build(BuildContext context) {
    final tabsLocked = isGenerating && !isGenerationPaused;

    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          NavigationTrail(
            stack: navigationStack,
            onJumpTo: onNavigationJump,
          ),
          if (tabsLocked)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Colors.orange.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
                child: const ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(Icons.lock_outline, size: 18),
                  title: Text(
                    'Generation is running. Pause or cancel to switch tabs.',
                  ),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: tabsLocked,
            child: Opacity(
              opacity: tabsLocked ? 0.35 : 1.0,
              child: TabBar(
                controller: tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(
                    text: 'Browse',
                    icon: Icon(Icons.explore, size: 16),
                  ),
                  Tab(
                    text: 'PGN',
                    icon: Icon(Icons.description, size: 16),
                  ),
                  Tab(
                    text: 'Lines',
                    icon: Icon(Icons.library_books, size: 16),
                  ),
                  Tab(
                    text: 'Generate',
                    icon: Icon(Icons.auto_awesome, size: 16),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: tabController,
              physics: tabsLocked
                  ? const NeverScrollableScrollPhysics()
                  : null,
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
