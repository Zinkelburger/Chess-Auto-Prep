import 'package:flutter/material.dart';

import '../../chess/players/download_range.dart';
import '../../chess/players/player.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';

Future<PlayerDownloadRange?> downloadRange(
  BuildContext context,
  Player player,
) => showDialog<PlayerDownloadRange>(
  context: context,
  builder: (_) => _DownloadDialog(player),
);

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog(this.player);
  final Player player;
  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  late final saved = PlayerDownloadRange.from(widget.player.fields['download']);
  bool months = false;
  int count = 500, monthCount = 6;
  Set<String> speeds = {};
  @override
  void initState() {
    super.initState();
    months = saved.months != null;
    count = saved.max;
    monthCount = saved.months ?? 6;
    speeds = {...saved.speeds};
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Download ${widget.player.name}’s games'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.player.accounts
                  .map((a) => '${a.site.label}: ${a.username}')
                  .join('\n'),
            ),
            const SizedBox(height: Space.m),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Last games')),
                ButtonSegment(value: true, label: Text('Recent months')),
              ],
              selected: {months},
              onSelectionChanged: (v) {
                if (mounted) setState(() => months = v.single);
              },
            ),
            const SizedBox(height: Space.m),
            if (months)
              NumberField(
                label: 'Months',
                value: monthCount,
                min: 1,
                max: 120,
                onChanged: (v) {
                  if (mounted) setState(() => monthCount = v);
                },
              )
            else
              NumberField(
                label: 'Games per account',
                value: count,
                min: 1,
                max: 10000,
                step: 100,
                onChanged: (v) {
                  if (mounted) setState(() => count = v);
                },
              ),
            const SizedBox(height: Space.m),
            const Text('Time controls'),
            Wrap(
              spacing: Space.s,
              children: [
                for (final entry in const {
                  'bullet': 'Bullet',
                  'blitz': 'Blitz',
                  'rapid': 'Rapid',
                  'classical': 'Classical',
                  'correspondence': 'Correspondence',
                }.entries)
                  FilterChip(
                    label: Text(entry.value),
                    selected: speeds.contains(entry.key),
                    onSelected: (v) {
                      if (mounted)
                        setState(() {
                          v ? speeds.add(entry.key) : speeds.remove(entry.key);
                        });
                    },
                  ),
              ],
            ),
            if (speeds.isEmpty) const Text('Choose at least one time control.'),
            const SizedBox(height: Space.s),
            const Text(
              'New games are added to saved games. Your existing games stay available.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: speeds.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                PlayerDownloadRange(
                  max: count,
                  months: months ? monthCount : null,
                  speeds: speeds,
                ),
              ),
        child: const Text('Download'),
      ),
    ],
  );
}
