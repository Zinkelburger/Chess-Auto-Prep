/// Tab labels for the repertoire screen's tools and side-panel tab bars.
/// Split out of lib/screens/repertoire_screen.dart.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// "PGN" tab label.
class RepertoirePgnTabLabel extends StatelessWidget {
  const RepertoirePgnTabLabel({super.key});

  @override
  Widget build(BuildContext context) {
    return const Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.article_outlined, size: 14),
          SizedBox(width: 4),
          Text('PGN', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// "Lines"/"Draft"/"Session" tab label; highlighted while a build-by-playing
/// session or a build-from-games draft is active.
class RepertoireLinesTabLabel extends StatelessWidget {
  const RepertoireLinesTabLabel({
    super.key,
    required this.isBuildSessionActive,
    required this.isDraftActive,
    required this.hasTraps,
  });

  final bool isBuildSessionActive;
  final bool isDraftActive;
  final bool hasTraps;

  @override
  Widget build(BuildContext context) {
    final highlight = isBuildSessionActive
        ? Theme.of(context).colorScheme.primary
        : isDraftActive
        ? AppColors.warning
        : null;
    return Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBuildSessionActive
                ? Icons.sports_esports
                : isDraftActive
                ? Icons.download_done
                : Icons.list_alt,
            size: 14,
            color: highlight,
          ),
          const SizedBox(width: 4),
          Text(
            isBuildSessionActive
                ? 'Session'
                : isDraftActive
                ? 'Draft'
                : 'Lines${hasTraps ? ' & Traps' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: highlight,
              fontWeight: highlight != null ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Tree" tab label.
class RepertoireTreeTabLabel extends StatelessWidget {
  const RepertoireTreeTabLabel({super.key});

  @override
  Widget build(BuildContext context) {
    return const Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 14),
          SizedBox(width: 4),
          Text('Tree', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
