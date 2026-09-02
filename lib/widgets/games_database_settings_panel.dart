/// Status of the user's own games database (`app_games.db`): how many
/// games are indexed per store.  Read-only — the collections are filled by
/// the downloads and imports that feed them.
library;

import 'package:flutter/material.dart';

import '../services/game_store/game_store.dart';
import '../services/game_store/game_store_service.dart';
import '../theme/app_colors.dart';

class GamesDatabaseSettingsPanel extends StatelessWidget {
  const GamesDatabaseSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<GameStore>(
      future: GameStoreService.instance.open(),
      builder: (context, snap) {
        final String body;
        if (snap.hasError) {
          body = 'Games database unavailable: ${snap.error}';
        } else if (!snap.hasData) {
          body = 'Opening…';
        } else {
          final counts = snap.data!.collectionCounts();
          if (counts.isEmpty) {
            body =
                'No games indexed yet. Player Analysis downloads, the home '
                'games library and the tactics archive fill it automatically.';
          } else {
            final total = counts.values.fold(0, (a, b) => a + b);
            final parts = <String>[];
            var tactics = 0, analysis = 0, library = 0, players = 0, users = 0;
            for (final e in counts.entries) {
              if (e.key == GameCollections.tactics) {
                tactics += e.value;
              } else if (e.key.startsWith('analysis:')) {
                analysis += e.value;
                players++;
              } else if (e.key.startsWith('library:')) {
                library += e.value;
                users++;
              }
            }
            if (analysis > 0) {
              parts.add('$analysis from Player Analysis ($players players)');
            }
            if (library > 0) {
              parts.add('$library in the games library ($users accounts)');
            }
            if (tactics > 0) parts.add('$tactics in the tactics archive');
            body = '$total games indexed — ${parts.join(', ')}.';
          }
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(body, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                snap.hasData ? snap.data!.path : '',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
