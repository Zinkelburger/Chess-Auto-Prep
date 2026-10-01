import 'package:flutter/material.dart';

import '../../chess/players/download_range.dart';
import '../../chess/players/player.dart';
import '../../ui/field_row.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import '../../ui/toggle_chip.dart';

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

  void _speed(String speed, bool on) {
    if (!mounted) return;
    setState(() => on ? speeds.add(speed) : speeds.remove(speed));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Get ${widget.player.name}’s games'),
      content: SizedBox(
        width: nameDialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.player.accounts
                    .map((a) => '${a.site.label} ${a.username}')
                    .join(' · '),
                style: text.bodySmall,
              ),
              const SizedBox(height: Space.m),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Last games')),
                  ButtonSegment(value: true, label: Text('Recent months')),
                ],
                selected: {months},
                showSelectedIcon: false,
                onSelectionChanged: (v) {
                  if (mounted) setState(() => months = v.single);
                },
              ),
              const SizedBox(height: Space.s),
              _amount(),
              const SizedBox(height: Space.s),
              ..._timeControls(context),
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
          child: const Text('Get games'),
        ),
      ],
    );
  }

  /// The time controls to download, and the line under them: always
  /// there, so the buttons do not move when the last chip goes off.
  List<Widget> _timeControls(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return [
      Text('Time controls', style: small),
      const SizedBox(height: Space.xs),
      Wrap(
        spacing: Space.xs,
        runSpacing: Space.xs,
        children: [
          for (final entry in _speedNames.entries)
            ToggleChip(
              label: entry.value,
              selected: speeds.contains(entry.key),
              onSelected: (on) => _speed(entry.key, on),
            ),
        ],
      ),
      const SizedBox(height: Space.s),
      Text(
        speeds.isEmpty
            ? 'Choose at least one time control.'
            : 'New games are added to the ones already saved.',
        style: small?.copyWith(
          color: speeds.isEmpty ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    ];
  }

  /// How far back to go, in the unit the switch above it chose.
  Widget _amount() => months
      ? FieldRow(
          label: 'Months',
          child: NumberField(
            label: 'Months',
            value: monthCount,
            min: 1,
            max: 120,
            onChanged: (v) {
              if (mounted) setState(() => monthCount = v);
            },
          ),
        )
      : FieldRow(
          label: 'Games per account',
          child: NumberField(
            label: 'Games per account',
            value: count,
            min: 1,
            max: 10000,
            step: 100,
            onChanged: (v) {
              if (mounted) setState(() => count = v);
            },
          ),
        );
}

const _speedNames = {
  'bullet': 'Bullet',
  'blitz': 'Blitz',
  'rapid': 'Rapid',
  'classical': 'Classical',
  'correspondence': 'Correspondence',
};
