import 'package:flutter/material.dart';

import '../../chess/players/player.dart';
import '../../chess/tactics/game_ids.dart';
import '../../ui/theme.dart';
import 'players.dart';

/// What the account research found for a person, folded under their row:
/// each suggested account with the evidence for it and the button that
/// links it. Nothing is linked until the user presses that button.
class PlayerLookup extends StatefulWidget {
  const PlayerLookup({super.key, required this.player, required this.owner});
  final Player player;
  final Players owner;

  @override
  State<PlayerLookup> createState() => _PlayerLookupState();
}

class _PlayerLookupState extends State<PlayerLookup> {
  bool _open = false;

  void _toggle() {
    if (mounted) setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final lookup = widget.player.fields['lookup'];
    if (lookup is! Map) return const SizedBox.shrink();
    final candidates = lookup['candidates'] is List
        ? (lookup['candidates'] as List).whereType<Map>().toList()
        : const <Map>[];
    final steps = lookup['next_steps'] is List
        ? lookup['next_steps'] as List
        : const [];
    final small = Theme.of(context).textTheme.labelSmall;
    final status = '${lookup['status'] ?? 'saved research'}'.replaceAll(
      '_',
      ' ',
    );
    final count = candidates.length;
    final words = count == 0
        ? 'Account lookup'
        : '$count suggested ${count == 1 ? 'account' : 'accounts'}';
    // With nothing to open it is one quiet line, not a button.
    if (candidates.isEmpty && steps.isEmpty) {
      return Text('$words · $status', style: small);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: _toggle,
              icon: Icon(
                _open ? Icons.expand_less : Icons.expand_more,
                size: IconSize.action,
              ),
              iconAlignment: IconAlignment.end,
              label: Text(words),
            ),
            Flexible(
              child: Text(
                status,
                style: small,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (_open) ...[
          for (final candidate in candidates) _candidate(candidate, lookup),
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.only(left: Space.m, top: Space.xs),
              child: Text('$step', style: small),
            ),
        ],
      ],
    );
  }

  Widget _candidate(Map candidate, Map lookup) {
    final theme = Theme.of(context);
    final owner = widget.owner;
    final site = GameSite.values
        .where((s) => s.name == candidate['site'])
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(left: Space.m),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${site?.label ?? candidate['site']} '
                  '${candidate['username']}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  '${candidate['evidence'] ?? 'No evidence saved.'}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed:
                owner.busy ||
                    owner.needsRetry ||
                    site == null ||
                    candidate['username'] is! String
                ? null
                : () => _use(candidate, lookup),
            child: const Text('Use account'),
          ),
        ],
      ),
    );
  }

  void _use(Map candidate, Map lookup) {
    final player = widget.player;
    final site = candidate['site'] as String;
    final names =
        player.accounts
            .where((a) => a.site.name == site)
            .map((a) => a.username)
            .toSet()
          ..add(candidate['username'] as String);
    widget.owner.save(
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
