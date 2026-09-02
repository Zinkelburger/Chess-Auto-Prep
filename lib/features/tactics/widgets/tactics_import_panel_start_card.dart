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
            // Titled after the button that opens it, like the analysis
            // gear: "Session Settings" named a concept the card never uses.
            title: const Text('Tactics filters'),
            // Scrollable: the form is a dozen rows tall and this dialog has
            // to survive a short window without a render overflow.
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: _SessionSettingsForm(
                  settings: draft,
                  showCustomType: _presentMistakeTypes.contains(
                    TacticsSessionSettings.customMistakeType,
                  ),
                  onChanged: (s) => setDialogState(() => draft = s),
                ),
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

  // ── Play block ─────────────────────────────────────────────────────────

  /// What you can play right now, counted by the only thing that means
  /// anything here — what kind of mistake it was — and the button that plays
  /// them. The count and the verb belong together; this is the one play
  /// button on the screen.
  ///
  /// The line says what is in the queue ("84 blunders, 51 mistakes"), never
  /// "157 of 842": the second number counted positions the filters have
  /// already ruled out and read as puzzles being kept from you.
  Widget _buildPlayBlock(int positionCount) {
    final matchingCount = _matchingCount;

    // A single line; exactly one variant renders so the block height is
    // stable.
    String line;
    Color color = AppColors.onSurfaceMuted;
    if (positionCount == 0) {
      // With auto-start on, the usual reason for an empty database is that the
      // analysis is still working — say so rather than telling the user to
      // press a button that is already running.
      line = widget.isImporting
          ? 'Analysing your games — the first puzzles appear here as they are '
                'found.'
          : 'No puzzles yet — analyse your games first.';
    } else if (matchingCount == 0) {
      line =
          'Nothing to play: your filters rule out every puzzle you have. '
          'Press Filters… to loosen them.';
      color = AppColors.warning;
    } else {
      line = 'Ready to play: $_readyBreakdown';
      if (widget.isImporting) {
        line = '$line — more are added as the review finds them';
      }
    }

    return HomeBlock(
      heading: 'Play',
      // The tooltip names what is behind the button, expiry first: "how long
      // do my puzzles last" is the question people go looking for.
      trailing: Tooltip(
        message:
            'How long puzzles stay in the queue, which mistake types to '
            'practise, and what order they come in',
        child: TextButton(
          onPressed: _showSessionSettingsDialog,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Text('Filters…'),
        ),
      ),
      children: [
        _buildPlayButton(positionCount, matchingCount),
        const SizedBox(height: 8),
        Text(line, style: AppTextStyles.muted.copyWith(color: color)),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerLeft,
          child: _conditionalTooltip(
            message: positionCount == 0 ? 'No tactics to browse' : null,
            child: TextButton(
              key: const Key('browse-tactics-button'),
              onPressed: positionCount > 0 ? widget.onBrowseTactics : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                positionCount > 0
                    ? 'Browse all $positionCount →'
                    : 'Browse all →',
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Play what the block just counted.
  ///
  /// It stays pressable during a review — the queue is whatever has been mined
  /// so far, and puzzles keep arriving behind you while you solve.
  Widget _buildPlayButton(int positionCount, int matchingCount) {
    final ready = matchingCount > 0;
    return _conditionalTooltip(
      message: ready
          ? null
          : positionCount == 0
          ? 'Nothing mined yet — analyse your games first'
          : 'Your filters rule out every puzzle you have; press Filters… to '
                'loosen them',
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: FilledButton.icon(
          key: const Key('play-tactics-button'),
          onPressed: ready ? _startSession : null,
          icon: const Icon(Icons.play_arrow, size: 22),
          label: Text(
            ready ? 'Play tactics ($matchingCount)' : 'Play tactics',
            style: AppTextStyles.bodyStrong,
          ),
        ),
      ),
    );
  }

  /// The panel owns the board and the session; the request goes through the
  /// shared controller.
  void _startSession() =>
      context.read<TacticsSessionController>().panel?.start?.call();

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
