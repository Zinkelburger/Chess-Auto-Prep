/// Tab labels for the repertoire screen's tools and side-panel tab bars.
/// Split out of lib/screens/repertoire_screen.dart.
library;

import 'package:flutter/material.dart';

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

/// "Chapters" tab label (with "& Traps" once the chapter has traps).
class RepertoireLinesTabLabel extends StatelessWidget {
  const RepertoireLinesTabLabel({super.key, required this.hasTraps});

  final bool hasTraps;

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book_outlined, size: 14),
          const SizedBox(width: 4),
          Text(
            'Chapters${hasTraps ? ' & Traps' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
