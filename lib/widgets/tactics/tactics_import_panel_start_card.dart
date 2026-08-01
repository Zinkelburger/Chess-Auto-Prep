part of 'tactics_import_panel.dart';

mixin _TacticsImportPanelStartCard on _TacticsImportPanelStateBase {
  int get _matchingCount => _settings.countMatching(widget.positions);

  /// Mistake types that actually occur in the current database — the Filters
  /// dialog only offers a "Custom puzzles" checkbox when there are some.
  Set<String> get _presentMistakeTypes => {
    for (final pos in widget.positions) pos.mistakeType,
  };

  Future<void> _showSessionSettingsDialog() async {
    var draft = _settings;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final matching = draft.countMatching(widget.positions);
          return AlertDialog(
            title: const Text('Session Settings'),
            content: SizedBox(
              width: 360,
              child: _SessionSettingsForm(
                settings: draft,
                showCustomType: _presentMistakeTypes.contains(
                  TacticsSessionSettings.customMistakeType,
                ),
                onChanged: (s) => setDialogState(() => draft = s),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  context.read<TacticsSessionController>().setSessionSettings(
                    draft,
                  );
                  Navigator.pop(ctx);
                },
                child: Text('Apply ($matching positions)'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Tactics card ───────────────────────────────────────────────────────

  /// What you can play right now, counted by the only thing that means anything
  /// here — what kind of mistake it was. The button that plays them is in the
  /// left pane under Review games; see the class doc on [TacticsImportPanel].
  ///
  /// This card used to say "157 of 842 puzzles ready to play". Both numbers
  /// were true and neither was answerable: 842 counted positions the filters
  /// have already ruled out (old games, mistake types switched off), so the
  /// pair read as "684 puzzles are being kept from you" with no way to tell
  /// why. What you actually want to know before pressing play is what is in
  /// the queue, and that is "84 blunders, 51 mistakes".
  Widget _buildStartCard(int positionCount) {
    final matchingCount = _matchingCount;

    // A single line; exactly one variant renders so the card height is stable.
    String line;
    Color color = AppColors.onSurfaceSoft;
    if (positionCount == 0) {
      line = 'No tactics yet — press Review games on the left to find some.';
    } else if (matchingCount == 0) {
      line =
          'Nothing to play: your filters rule out every puzzle you have. '
          'Press Filters… to loosen them.';
      color = AppColors.warning;
    } else {
      line = 'Ready to play: $_readyBreakdown';
      if (widget.isImporting) {
        line = '$line — more are added as the review finds them';
        color = AppColors.success;
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'My tactics',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: _showSessionSettingsDialog,
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Filters…'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(line, style: TextStyle(fontSize: 12.5, color: color)),
          ],
        ),
      ),
    );
  }

  /// Plural/singular noun per mistake type, in the order they are worth
  /// looking at.
  static const _typeNouns = <String, (String, String)>{
    '??': ('blunder', 'blunders'),
    '?': ('mistake', 'mistakes'),
    '?!': ('inaccuracy', 'inaccuracies'),
    TacticsSessionSettings.customMistakeType: (
      'custom puzzle',
      'custom puzzles',
    ),
  };

  /// "84 blunders, 51 mistakes" — the playable queue by kind. Types with none
  /// in it are left out rather than shown as a zero: a row of zeroes is noise,
  /// and the Filters dialog is where you go to change what counts.
  String get _readyBreakdown {
    final counts = <String, int>{};
    for (final pos in widget.positions) {
      if (_settings.accepts(pos)) {
        counts[pos.mistakeType] = (counts[pos.mistakeType] ?? 0) + 1;
      }
    }
    final parts = <String>[
      for (final entry in _typeNouns.entries)
        if ((counts[entry.key] ?? 0) > 0)
          '${counts[entry.key]} '
              '${counts[entry.key] == 1 ? entry.value.$1 : entry.value.$2}',
    ];
    // Any mistake type the database grew that this map doesn't name.
    final named = _typeNouns.keys.toSet();
    final other = counts.entries
        .where((e) => !named.contains(e.key))
        .fold(0, (sum, e) => sum + e.value);
    if (other > 0) parts.add('$other other');
    return parts.join(', ');
  }
}
