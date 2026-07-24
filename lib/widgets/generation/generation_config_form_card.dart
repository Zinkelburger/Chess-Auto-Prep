part of 'generation_config_form.dart';

/// Layer-1 "state your intent" card: opponent, style, effort, source —
/// plus the presets menu and the live plain-language summary.  Every
/// control here is a projection over the same underlying knobs the
/// advanced dialog edits, so the two can never disagree.
mixin _GenerationConfigCard
    on
        _GenerationConfigFormStateBase,
        _GenerationConfigDescriptions,
        _GenerationConfigFields,
        _GenerationConfigIo {
  static const List<int> _lichessRatingBuckets = [
    1000,
    1200,
    1400,
    1600,
    1800,
    2000,
    2200,
    2500,
  ];

  // ── Derived intent state ────────────────────────────────────────────────

  int get _opponentElo =>
      ((int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200).clamp(1100, 2500) / 50)
          .round() *
      50;

  RepertoireStyle? get _currentStyle => detectStyle(
    selectionMode: _selectionMode,
    setupMoves: _setupMovesCtrl.text,
  );

  EffortPreset? get _currentEffort => EffortPreset.detect(
    maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? -1,
    evalDepth: int.tryParse(_engineDepthCtrl.text.trim()) ?? -1,
    ourMultipv: int.tryParse(_multipvCtrl.text.trim()) ?? -1,
    verifyFinal: _verifyFinal,
    wideOpening: _wideOpening,
  );

  void _applyStyle(RepertoireStyle style) {
    _selectionMode = style.selectionMode;
    // A hidden setup list steering a "Solid" repertoire is exactly the
    // silent coupling this card exists to kill — clear it on style change.
    if (style != RepertoireStyle.system) _setupMovesCtrl.clear();
  }

  void _applyEffort(EffortPreset preset) {
    _maxPlyCtrl.text = preset.maxPly.toString();
    _engineDepthCtrl.text = preset.evalDepth.toString();
    _multipvCtrl.text = preset.ourMultipv.toString();
    _verifyFinal = preset.verifyFinal;
    _wideOpening = preset.wideOpening;
  }

  void _setOpponentElo(int elo) {
    _maiaEloCtrl.text = elo.toString();
    if (_lichessDbOverride != null) {
      // Keep the DB rating bucket in step with the slider; fine-grained
      // multi-bucket selection stays available in the advanced dialog.
      final nearest = _lichessRatingBuckets.reduce(
        (a, b) => (a - elo).abs() <= (b - elo).abs() ? a : b,
      );
      _lichessRatings
        ..clear()
        ..add(nearest.toString());
    }
  }

  // ── Card rows ───────────────────────────────────────────────────────────

  Widget _opponentRow() {
    final elo = _opponentElo;
    final source = _lichessDbOverride == null
        ? 'Maia neural opponent (human-like)'
        : (_lichessDbOverride == LichessDatabase.masters
              ? 'Lichess Masters database'
              : 'Lichess players database');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Opponent strength', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: elo.toDouble(),
                min: 1100,
                max: 2500,
                divisions: 28,
                label: '~$elo',
                onChanged: widget.isGenerating
                    ? null
                    : (v) => setState(() => _setOpponentElo(v.round())),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(
                '~$elo',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        _caption('Modelled as: $source — change under Advanced.'),
        if (_lichessDbOverride != null) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final speed in const [
                'bullet',
                'blitz',
                'rapid',
                'classical',
              ])
                FilterChip(
                  label: Text(speed, style: const TextStyle(fontSize: 11)),
                  selected: _lichessSpeeds.contains(speed),
                  onSelected: widget.isGenerating
                      ? null
                      : (on) => setState(() {
                          if (on) {
                            _lichessSpeeds.add(speed);
                          } else if (_lichessSpeeds.length > 1) {
                            _lichessSpeeds.remove(speed);
                          }
                        }),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _styleRow() {
    final style = _currentStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Style', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<RepertoireStyle>(
                segments: [
                  for (final s in RepertoireStyle.values)
                    ButtonSegment(
                      value: s,
                      label: Text(
                        s.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                      tooltip: s.description,
                    ),
                ],
                selected: style != null ? {style} : {},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: widget.isGenerating
                    ? null
                    : (sel) {
                        if (sel.isEmpty) return;
                        setState(() => _applyStyle(sel.first));
                      },
              ),
            ),
          ],
        ),
        _caption(
          style?.description ??
              'Custom line selection '
                  '(${_selectionModeLabel(_selectionMode)}) — set under '
                  'Advanced.',
        ),
        if (style == RepertoireStyle.system) ...[
          const SizedBox(height: 8),
          _setupMovesField(),
        ],
      ],
    );
  }

  Widget _setupMovesField() {
    return TextField(
      controller: _setupMovesCtrl,
      enabled: !widget.isGenerating,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        labelText: 'Your system\'s moves (SAN, any order)',
        hintText: 'e.g. Be3 Qd2 f3 O-O-O h4 Nh3',
        helperText:
            'Played whenever they stay sound; the repertoire deviates '
            'automatically when the opponent makes them too costly.',
        helperMaxLines: 2,
        isDense: true,
        border: OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _effortRow() {
    final effort = _currentEffort;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Effort', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<EffortLevel>(
                segments: [
                  for (final p in EffortPreset.all)
                    ButtonSegment(
                      value: p.level,
                      label: Text(
                        p.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                      tooltip:
                          '${p.maxPly} half-moves deep · engine depth '
                          '${p.evalDepth} · '
                          '${p.verifyFinal ? 'verified' : 'unverified'} · '
                          'usually ${p.timeHint}',
                    ),
                ],
                selected: effort != null ? {effort.level} : {},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: widget.isGenerating
                    ? null
                    : (sel) {
                        if (sel.isEmpty) return;
                        setState(
                          () => _applyEffort(
                            EffortPreset.all.firstWhere(
                              (p) => p.level == sel.first,
                            ),
                          ),
                        );
                      },
              ),
            ),
          ],
        ),
        _caption(
          effort != null
              ? 'Usually ${effort.timeHint} on a desktop machine.'
              : 'Custom search settings (set under Advanced).',
        ),
      ],
    );
  }

  Widget _sourceRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Build from', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<BuildMode>(
                initialValue: _buildMode,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: BuildMode.stockfishExpectimax,
                    child: Text(
                      'Engine + human model (recommended)',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  DropdownMenuItem(
                    value: BuildMode.maiaDbExplore,
                    child: Text(
                      'Database win rates (no engine)',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  DropdownMenuItem(
                    value: BuildMode.dbExplorer,
                    child: Text('My PGN files', style: TextStyle(fontSize: 13)),
                  ),
                ],
                onChanged: widget.isGenerating
                    ? null
                    : (v) {
                        if (v != null) setState(() => _buildMode = v);
                      },
              ),
            ),
          ],
        ),
        _caption(_buildModeDescription()),
        if (_buildMode == BuildMode.dbExplorer) ...[
          const SizedBox(height: 8),
          PgnSourcesPanel(
            key: _pgnSourcesKey,
            initialSources: null,
            onSourcesChanged: (sources) {
              _pgnFilePaths
                ..clear()
                ..addAll(
                  sources
                      .where((s) => s.filePath != null)
                      .map((s) => s.filePath!),
                );
            },
          ),
        ],
      ],
    );
  }

  // ── Presets menu ────────────────────────────────────────────────────────

  Future<void> _reloadPresets() async {
    final presets = await _presetStore.load();
    if (!mounted) return;
    setState(() => _savedPresets = presets);
  }

  void _applyPresetJson(Map<String, dynamic> json) {
    setState(() {
      _applyInitialConfig(TreeBuildConfig.fromJson(json, startFen: ''));
    });
  }

  void _resetToDefaults() {
    setState(() {
      _applyInitialConfig(
        TreeBuildConfig(
          startFen: '',
          playAsWhite: widget.playAsWhite,
          minEvalCp: widget.playAsWhite ? 0 : -100,
          maxEvalCp: widget.playAsWhite ? 200 : 100,
        ),
      );
    });
  }

  Future<void> _saveCurrentAsPreset() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save settings as preset'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Preset name',
              hintText: 'e.g. Anti-London deep prep',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty) return;
    await _presetStore.save(
      name,
      toConfig(startFen: '', playAsWhite: widget.playAsWhite),
    );
    await _reloadPresets();
  }

  Widget _presetsMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Saved setting presets',
      enabled: !widget.isGenerating,
      onSelected: (value) async {
        switch (value) {
          case '::reset':
            _resetToDefaults();
          case '::save':
            await _saveCurrentAsPreset();
          default:
            final json = _savedPresets[value];
            if (json != null) _applyPresetJson(json);
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(value: '::reset', child: Text('Reset to defaults')),
        const PopupMenuItem(
          value: '::save',
          child: Text('Save current as preset…'),
        ),
        if (_savedPresets.isNotEmpty) const PopupMenuDivider(),
        for (final name in _savedPresets.keys)
          PopupMenuItem(
            value: name,
            child: Row(
              children: [
                Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  tooltip: 'Delete preset',
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await _presetStore.delete(name);
                    await _reloadPresets();
                  },
                ),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: const Icon(Icons.bookmark_outline, size: 16),
        label: Text(
          _savedPresets.isEmpty
              ? 'Presets'
              : 'Presets (${_savedPresets.length})',
          style: const TextStyle(fontSize: 12),
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  // ── Summary ─────────────────────────────────────────────────────────────

  String _summaryText() {
    final style = _currentStyle;
    final effort = _currentEffort;
    final styleTxt = style != null
        ? style.label
        : 'Custom (${_selectionModeLabel(_selectionMode)})';
    final source = switch (_buildMode) {
      BuildMode.stockfishExpectimax => 'engine + human model',
      BuildMode.maiaDbExplore => 'database win rates',
      BuildMode.dbExplorer => 'your PGN files',
      BuildMode.trapFinder => 'trap finder',
    };
    final ply = int.tryParse(_maxPlyCtrl.text.trim()) ?? 20;
    final parts = [
      '$styleTxt repertoire vs ~$_opponentElo',
      source,
      '$ply half-moves deep',
      if (_verifyFinal) 'verified',
      if (effort != null) 'usually ${effort.timeHint}',
    ];
    return parts.join(' · ');
  }

  Widget _summary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.rowStripe,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(_summaryText(), style: const TextStyle(fontSize: 12)),
    );
  }
}
