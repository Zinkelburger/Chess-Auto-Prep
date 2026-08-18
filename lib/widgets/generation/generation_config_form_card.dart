part of 'generation_config_form.dart';

/// The always-visible generation form: opponent rating, the two search
/// algorithms with their three numbers, the two output switches, and the
/// build source.  Everything here is a real knob with a real name — no
/// bundled "style" or "effort" modifiers that quietly rewrite several
/// settings at once.  Rarely-touched knobs live in the Advanced dialog and
/// edit the same controllers, so the two can never disagree.
mixin _GenerationConfigCard
    on
        _GenerationConfigFormStateBase,
        _GenerationConfigDescriptions,
        _GenerationConfigFields,
        _GenerationConfigIo {
  // ── Section chrome ──────────────────────────────────────────────────────

  /// Titled block with a rule above it, so the form reads as four short
  /// lists instead of one wall of controls.
  Widget _cardSection(
    String title,
    List<Widget> children, {
    bool leadingRule = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leadingRule) const Divider(height: 24),
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.onSurfaceSoft,
          ),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    );
  }

  // ── Opponent ────────────────────────────────────────────────────────────

  Widget _opponentSection() {
    return _cardSection('Opponent', leadingRule: false, [
      _numField(
        _maiaEloCtrl,
        'Opponent rating (Elo)',
        defaultText: '2200',
        onEdited: () => setState(() {}),
        tooltip:
            'The rating the opponent model plays at. Everything about how '
            'likely a reply is comes from this number. Set it to the '
            'rating of opponents you usually face.',
      ),
      _caption(
        _buildMode == BuildMode.dbExplorer
            ? 'Opponent replies come from move frequencies in your PGN '
                  'files; this rating still drives annotations and trap '
                  'findability.'
            : 'Replies are predicted by Maia at this rating. For frequencies '
                  'from real games, build from a PGN database instead.',
      ),
    ]);
  }

  // ── Search ──────────────────────────────────────────────────────────────

  /// Coverage-floor phrase for the Fast caption, live from the Advanced
  /// field; 0 or unparsable falls back to the generic wording.
  String _coverageFloorPhrase() {
    final floor = double.tryParse(_coverMinProbCtrl.text.trim()) ?? 0;
    if (floor <= 0 || floor > 1) {
      return 'every covered reply still gets an answer';
    }
    final pct = (floor * 1000).roundToDouble() / 10;
    final pctText = pct == pct.roundToDouble()
        ? pct.round().toString()
        : pct.toStringAsFixed(1);
    return 'every reply seen more than $pctText% of the time still gets '
        'an answer';
  }

  String _searchAlgorithmCaption() {
    final budget = int.tryParse(_timeBudgetCtrl.text.trim()) ?? 0;
    return switch (_searchAlgorithm) {
      SearchAlgorithm.fast =>
        budget > 0
            ? 'Expands the most likely positions first and stops after '
                  '$budget minute${budget == 1 ? '' : 's'}. Rare side lines '
                  'get a narrower search; ${_coverageFloorPhrase()}.'
            : 'Expands the most likely positions first and searches rare '
                  'side lines more narrowly. Set a time limit below to make '
                  'it stop early instead of finishing the whole tree.',
      SearchAlgorithm.pure =>
        budget > 0
            ? 'Searches every position level by level at the full candidate '
                  'width — but with a time limit it stops mid-breadth and '
                  'leaves every line equally shallow. Fast makes far '
                  'better use of a time limit.'
            : 'Level by level, every position at the full candidate width '
                  'and the eval window set under Advanced — no extra '
                  'narrowing for rare lines. Much slower.',
    };
  }

  Widget _searchSection() {
    return _cardSection('Search', [
      SegmentedButton<SearchAlgorithm>(
        segments: const [
          ButtonSegment(
            value: SearchAlgorithm.fast,
            label: Text('Fast (recommended)', style: TextStyle(fontSize: 12)),
            icon: Icon(Icons.bolt, size: 16),
          ),
          ButtonSegment(
            value: SearchAlgorithm.pure,
            label: Text('Pure', style: TextStyle(fontSize: 12)),
            icon: Icon(Icons.all_inclusive, size: 16),
          ),
        ],
        selected: {_searchAlgorithm},
        showSelectedIcon: false,
        onSelectionChanged: widget.isGenerating
            ? null
            : (sel) => setState(() => _searchAlgorithm = sel.first),
      ),
      _caption(_searchAlgorithmCaption()),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _engineDepthCtrl,
            'Engine depth',
            defaultText: '$kDefaultGenerationEvalDepth',
            onEdited: () => setState(() {}),
            enabled: _buildMode != BuildMode.maiaDbExplore,
            disabledReason: 'Evals come from databases in this build source',
            tooltip:
                'Stockfish search depth at every evaluated position — '
                'during the build, or in the eval pass run after a '
                'PGN-file tree is built.',
          ),
          _numField(
            _maxPlyCtrl,
            'Max line length (half-moves)',
            defaultText: '20',
            onEdited: () => setState(() {}),
            tooltip: 'How deep lines are allowed to grow.',
          ),
          _numField(
            _multipvCtrl,
            'Your candidate moves per position',
            defaultText: '4',
            onEdited: () => setState(() {}),
            enabled: _buildMode != BuildMode.dbExplorer,
            disabledReason:
                'Your PGN files decide the candidate moves in this mode',
            tooltip:
                'How many of your candidate moves are considered at each '
                'position — engine MultiPV lines, or top Maia moves in '
                'database mode.',
          ),
          _numField(
            _timeBudgetCtrl,
            'Stop after (minutes, 0 = no limit)',
            defaultText: '0',
            onEdited: () => setState(() {}),
            tooltip:
                '0 = no limit. With a limit the build stops expanding when '
                'time runs out, still answers every covered reply, and can '
                'be resumed later. Eval enrichment and verification run '
                'afterwards and are not counted against the limit.',
          ),
        ],
      ),
    ]);
  }

  // ── Output ──────────────────────────────────────────────────────────────

  Widget _outputSection() {
    final isDb = _buildMode == BuildMode.dbExplorer;
    return _cardSection('What to build', [
      DropdownButtonFormField<BuildMode>(
        initialValue: _buildMode,
        decoration: const InputDecoration(
          labelText: 'Build from',
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
      _caption(_buildModeDescription()),
      const SizedBox(height: 8),
      _labeledCheckbox(
        'Prefer novelties',
        _preferNovelties,
        (v) => setState(() => _preferNovelties = v),
        tooltip:
            'Boost sound-but-rare moves so opponents leave their '
            'preparation sooner. While on, the Natural-move tolerance '
            '(Advanced → Move choice) is ignored.',
      ),
      _labeledCheckbox(
        'Only traps',
        _trapsOnly,
        (v) => setState(() => _trapsOnly = v),
        tooltip:
            'Export only the lines that run through a trap — a position '
            'where the opponent has a tempting move that loses. The search '
            'is unchanged; everything that teaches no trap is dropped from '
            'the PGN, so you get a trap collection, not a repertoire.',
      ),
      const SizedBox(height: 8),
      _caption(
        isDb
            ? 'PGN files used for this build:'
            : 'Used only when "Build from" is My PGN files.',
      ),
      const SizedBox(height: 4),
      // Always mounted so the sources list survives mode switches; toConfig
      // only consumes it in db-explorer mode.
      IgnorePointer(
        ignoring: !isDb,
        child: Opacity(
          opacity: isDb ? 1 : 0.45,
          child: PgnSourcesPanel(
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
        ),
      ),
    ]);
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
          // The form's declared default; TreeBuildConfig's own is 50.
          maxEvalLossCp: 30,
        ),
      );
    });
    showAppSnackBar(context, 'Settings reset to defaults');
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

  /// Collapsible skeleton-plan editor — the repertoire-planning front door.
  Widget _skeletonSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showSkeleton = !_showSkeleton),
          child: Row(
            children: [
              Icon(
                _showSkeleton ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: AppColors.onSurfaceSoft,
              ),
              const SizedBox(width: 4),
              const Text(
                'Your lines & structures (optional)',
                style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
              ),
              const SizedBox(width: 4),
              const Tooltip(
                message:
                    'Give the build the lines you already know you want and '
                    'the structures to avoid. It pins your moves, answers '
                    'other move-orders the same way where sound, and steers '
                    'clear of the structures you dislike.',
                child: Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
        Offstage(
          offstage: !_showSkeleton,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SkeletonPlanCard(
              key: _skeletonKey,
              playAsWhite: widget.playAsWhite,
            ),
          ),
        ),
      ],
    );
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
            if (json != null) {
              _applyPresetJson(json);
              showAppSnackBar(context, 'Applied preset "$value"');
            }
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
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  onPressed: () => _confirmDeletePreset(ctx, name),
                ),
              ],
            ),
          ),
      ],
      // IgnorePointer keeps the tap on the PopupMenuButton while the
      // TextButton only paints the enabled/disabled button visuals.
      child: IgnorePointer(
        child: TextButton.icon(
          onPressed: widget.isGenerating ? null : () {},
          icon: const Icon(Icons.bookmark_outline, size: 16),
          label: Text(
            _savedPresets.isEmpty
                ? 'Presets…'
                : 'Presets (${_savedPresets.length})…',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeletePreset(
    BuildContext menuContext,
    String name,
  ) async {
    Navigator.of(menuContext).pop();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('Delete preset "$name"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _presetStore.delete(name);
    await _reloadPresets();
  }

  // ── Summary ─────────────────────────────────────────────────────────────

  String _summaryText() {
    final elo = int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200;
    final ply = int.tryParse(_maxPlyCtrl.text.trim()) ?? 20;
    final depth =
        int.tryParse(_engineDepthCtrl.text.trim()) ??
        kDefaultGenerationEvalDepth;
    final budget = int.tryParse(_timeBudgetCtrl.text.trim()) ?? 0;
    final source = switch (_buildMode) {
      BuildMode.stockfishExpectimax => 'engine + human model',
      BuildMode.maiaDbExplore => 'database win rates',
      BuildMode.dbExplorer => 'your PGN files',
      BuildMode.trapFinder => 'trap finder',
    };
    final parts = [
      _searchAlgorithm == SearchAlgorithm.fast ? 'Fast search' : 'Pure search',
      'vs ~$elo',
      source,
      '$ply half-moves deep',
      if (_buildMode == BuildMode.stockfishExpectimax) 'engine depth $depth',
      _selectionModeLabel(
        _selectionMode,
      ).replaceAll(' (recommended)', '').toLowerCase(),
      if (_preferNovelties) 'novelties',
      if (_trapsOnly) 'traps only',
      if (_verifyFinal && _buildMode != BuildMode.maiaDbExplore) 'verified',
      if (budget > 0) 'stops after ${budget}m',
    ];
    return parts.join(' · ');
  }

  Widget _summary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceInset,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(_summaryText(), style: const TextStyle(fontSize: 12)),
    );
  }
}
