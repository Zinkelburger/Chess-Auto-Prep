import 'package:flutter/material.dart';

import '../../services/opening_catalog.dart';
import '../../theme/app_text_styles.dart';

/// Optional reading detail; resolving a code never modifies the source PGN.
class PgnOpeningLabel extends StatelessWidget {
  const PgnOpeningLabel({super.key, required this.headers});

  final Map<String, String> headers;

  String _tag(String key) {
    final value = headers[key]?.trim() ?? '';
    return value == '?' ? '' : value;
  }

  @override
  Widget build(BuildContext context) {
    final eco = _tag('ECO');
    final name = _tag('Opening');
    if (name.isEmpty && eco.isEmpty) return const SizedBox.shrink();
    if (name.isNotEmpty) return _label(name, eco);
    return FutureBuilder<List<CatalogOpening>>(
      future: OpeningCatalog.load(),
      builder: (context, snapshot) {
        CatalogOpening? match;
        for (final entry in snapshot.data ?? <CatalogOpening>[]) {
          // A code covers several lines. Use its earliest named position,
          // without claiming the game reached a more specific subvariation.
          if (entry.eco == eco &&
              (match == null || entry.moves.length < match.moves.length)) {
            match = entry;
          }
        }
        return _label(
          match?.name ??
              (snapshot.connectionState == ConnectionState.waiting
                  ? 'Loading opening…'
                  : 'Opening name unavailable'),
          eco,
        );
      },
    );
  }

  Widget _label(String name, String eco) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'ECO is the Encyclopaedia of Chess Openings classification.',
        child: SelectableText(
          eco.isEmpty ? name : '$name (ECO $eco)',
          style: AppTextStyles.body,
        ),
      ),
    ),
  );
}
