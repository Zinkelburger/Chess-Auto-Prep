part of 'tactics_import_panel.dart';

mixin _TacticsImportPanelStartCard on _TacticsImportPanelStateBase {
  int get _matchingCount => _settings.countMatching(widget.positions);

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
                  setState(() => _settings = draft);
                  draft.save();
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

  // ── Start card ─────────────────────────────────────────────────────────

  Widget _buildStartCard(int positionCount) {
    final matchingCount = _matchingCount;

    // A single helper line under the button; exactly one variant renders so
    // the card height stays stable.
    // Only shown when the user needs to act (or wait); no hint in the
    // ordinary ready state — the button's "(N ready)" already says it all.
    String? hint;
    Color hintColor = Colors.grey[400]!;
    if (positionCount == 0) {
      hint = 'No tactics yet — import your games above to get started.';
    } else if (matchingCount == 0) {
      hint =
          'All $positionCount positions are filtered out — '
          'loosen the filters.';
      hintColor = Colors.orange[300]!;
    } else if (widget.isImporting) {
      hint = 'Import is running — new tactics are added as they\'re found.';
      hintColor = Colors.green[400]!;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Practice', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildFilterSummaryRow(),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: matchingCount > 0
                    ? () => widget.onStartSession(_settings)
                    : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  'Start Practice Session ($matchingCount ready)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(hint, style: TextStyle(fontSize: 12, color: hintColor)),
            ],
          ],
        ),
      ),
    );
  }

  static String _recencyLabel(int? maxAgeDays) => switch (maxAgeDays) {
    null => 'All time',
    1 => 'Today',
    final d => 'Last $d days',
  };

  static const _mistakeTypeNames = {
    '??': 'Blunders',
    '?': 'Mistakes',
    '?!': 'Inaccuracies',
    TacticsSessionSettings.customMistakeType: 'Custom puzzles',
  };

  /// Mistake types that actually occur in the current database.
  Set<String> get _presentMistakeTypes => {
    for (final pos in widget.positions) pos.mistakeType,
  };

  String get _mistakeTypesLabel {
    // Only talk about types the database actually has — mentioning "Custom
    // puzzles" when there are none just confuses. With an empty database,
    // fall back to the standard three.
    final present = _presentMistakeTypes;
    final relevant = present.isEmpty
        ? (_mistakeTypeNames.keys.toSet()
            ..remove(TacticsSessionSettings.customMistakeType))
        : present;
    final selected = [
      for (final entry in _mistakeTypeNames.entries)
        if (relevant.contains(entry.key) &&
            _settings.mistakeTypes.contains(entry.key))
          entry.value,
    ];
    if (selected.isEmpty) return 'No mistake types selected';
    if (selected.length == relevant.length && relevant.length >= 3) {
      return 'All mistake types';
    }
    return selected.join(', ');
  }

  /// One plain-text summary of the active session filter plus a single,
  /// clearly-labeled button that opens the settings dialog.
  Widget _buildFilterSummaryRow() {
    final summary =
        '${_recencyLabel(_settings.maxAgeDays)} · $_mistakeTypesLabel';
    return Row(
      children: [
        Icon(Icons.filter_alt_outlined, size: 14, color: Colors.grey[500]),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            summary,
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: _showSessionSettingsDialog,
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('Filters…'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }
}
