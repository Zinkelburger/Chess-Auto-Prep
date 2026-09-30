import 'package:flutter/material.dart';

import '../../chess/players/player.dart';
import 'players.dart';

/// Evidence stays visible until the user explicitly links an account.
class PlayerLookup extends StatelessWidget {
  const PlayerLookup({super.key, required this.player, required this.owner});
  final Player player;
  final Players owner;
  @override
  Widget build(BuildContext context) {
    final lookup = player.fields['lookup'];
    if (lookup is! Map) return const SizedBox.shrink();
    final candidates = lookup['candidates'] is List
        ? (lookup['candidates'] as List).whereType<Map>()
        : const <Map>[];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        candidates.isEmpty
            ? 'Account lookup'
            : '${candidates.length} suggested accounts',
      ),
      subtitle: Text(
        '${lookup['status'] ?? 'Saved research'}'.replaceAll('_', ' '),
      ),
      children: [
        for (final candidate in candidates)
          ListTile(
            title: Text('${candidate['site']}: ${candidate['username']}'),
            subtitle: Text('${candidate['evidence'] ?? 'No evidence saved.'}'),
            trailing: TextButton(
              onPressed:
                  owner.busy ||
                      owner.needsRetry ||
                      !{'chesscom', 'lichess'}.contains(candidate['site']) ||
                      candidate['username'] is! String
                  ? null
                  : () => _use(candidate, lookup),
              child: const Text('Use account'),
            ),
          ),
        if (lookup['next_steps'] case final List steps)
          for (final step in steps) ListTile(title: Text('$step')),
      ],
    );
  }

  void _use(Map candidate, Map lookup) {
    final site = candidate['site'] as String;
    final names =
        player.accounts
            .where((a) => a.site.name == site)
            .map((a) => a.username)
            .toSet()
          ..add(candidate['username'] as String);
    owner.save(
      player.edited({
        site: names.join(', '),
        'lookup': {
          ...lookup,
          'status': 'account',
          'confirmed': [
            ...?lookup['confirmed'] as List?,
            {...candidate, 'confirmed_by': 'user'},
          ],
          'candidates': [
            for (final c in lookup['candidates'] as List)
              if (!identical(c, candidate)) c,
          ],
        },
      }),
      expected: player,
    );
  }
}
