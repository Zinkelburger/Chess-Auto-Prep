part of 'generation_config_form.dart';

/// The always-visible generation form: opponent rating, the two search
/// algorithms with their three numbers, the two output switches, and the
/// build source.  Everything here is a real knob with a real name — no
/// hidden modifiers. The ChessDB starter profile is explicit and optional.
/// Rarely touched knobs live in the Advanced dialog and
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
            fontSize: 12,
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
    if (_buildMode == BuildMode.chessDbBook) {
      return _cardSection('Opponent replies', [
        _labeledCheckbox(
          'Cover replies from master games',
          _useMasterGames,
          (v) => setState(() => _useMasterGames = v),
          tooltip: 'Off, follow a single ChessDB mainline for both sides.',
        ),
        _caption(
          'One ChessDB move for your side; master-game replies for your opponent. '
          'Outside master practice, continue with one ChessDB mainline. No Maia model.',
        ),
        ..._masterGamesDownloadRow(),
      ]);
    }
    return _cardSection('Opponent', [
      if (_buildMode != BuildMode.stockfishExpectimax)
        _labeledCheckbox(
          'Target master opponents',
          _useMasterGames,
          (v) => setState(() => _useMasterGames = v),
          tooltip:
              'Use master-game reply frequencies where available; Maia supplies off-book positions. Untick to use Maia throughout.',
        ),
      _numField(
        _maiaEloCtrl,
        'Opponent rating (Elo)',
        defaultText: '2200',
        onEdited: () => setState(() {}),
        tooltip:
            'Maia predicts opponent replies at this rating in Pure and Fast search.',
      ),
      _caption(
        _buildMode == BuildMode.dbExplorer
            ? 'Opponent replies come from move frequencies in your PGN '
                  'files; this rating still drives annotations and trap '
                  'findability.'
            : _buildMode == BuildMode.stockfishExpectimax
            ? 'Maia predicts every reply at this rating. Stockfish evaluates positions; no game database is used.'
            : _useMasterGames
            ? 'Master-game frequencies where available; Maia at this rating off book. '
                  'If the master database is missing, replies come from Maia.'
            : 'Maia predicts every reply at this rating. Master-game frequencies are disabled.',
      ),
      // Master practice is what turns predicted replies into moves titled
      // players actually chose, so the offer to fetch it belongs beside the
      // rating rather than in the Advanced dialog, where nobody found it.
      ..._masterGamesDownloadRow(),
    ]);
  }

  /// The one-time "fetch the master games first" offer.  Present only while
  /// the database is empty and this build is set to use it — once the games
  /// are there the row is gone for good, and the on/off switch itself stays
  /// in Advanced where the other master-games knobs live.
  List<Widget> _masterGamesDownloadRow() {
    // Nullable watch: forms hosted without the app-level providers (widget
    // tests, previews) simply show no row.
    if (_buildMode == BuildMode.stockfishExpectimax) return const [];
    final service = context.watch<MasterGamesService?>();
    if (service == null || !service.isLoaded) return const [];
    if (!_useMasterGames || service.hasGames) return const [];

    final years = _masterGamesYears(service);
    final gb = (years * 0.6).round();
    return [
      const SizedBox(height: 10),
      _labeledCheckbox(
        'Download master games first (about $gb GB, once)',
        _downloadMasterGamesIfMissing,
        (v) => setState(() => _downloadMasterGamesIfMissing = v),
        tooltip:
            'The database is empty. Ticked, the build waits for the last '
            '$years years of The Week in Chess to download, then builds on '
            'master practice. Unticked, ChessDB books follow a single mainline '
            'without it; other modes use Maia. Also in Settings → Master games.',
      ),
      _caption(
        service.isSyncing
            ? 'A download is already running — the build waits for it '
                  'to finish.'
            : _buildMode == BuildMode.chessDbBook
            ? 'Without master games, a ChessDB book has no opponent branches. '
                  'This download can be reused by future builds.'
            : 'One download for every future build. Untick to build now '
                  'without master practice.',
      ),
    ];
  }

  /// Years of TWIC the service is set to fetch, matching the Settings
  /// stepper, so the size estimate here and there agree.
  int _masterGamesYears(MasterGamesService service) {
    final years =
        ((twicIssueEstimateFor(DateTime.now()) - service.startIssue) / 52)
            .round();
    return years < 1 ? 1 : years;
  }

  // ── Search ──────────────────────────────────────────────────────────────

  /// The model assumptions belong beside the visible search controls.
  String _searchAlgorithmCaption() =>
      _searchAlgorithm == SearchAlgorithm.rolling
      ? 'At each of our turns, compare candidates with 4 plies of lookahead, commit the best move, '
            'then extend every modeled opponent reply. Earlier choices stay committed. '
            'This can miss ideas beyond the window; it is an approximate policy, not a full-depth optimum. '
            'At 4 plies or less it does as much lookahead as Pure; longer preparation can still be expensive. '
            'The same engine-loss limit and draw convention as Pure apply.'
      : 'Pure finite-horizon search: start with 4 plies; each extra ply can multiply work. All legal candidates, '
            'one opponent model, no heuristic bonuses. A budget-limited result is incomplete. '
            'Scores are engine-derived expected-score estimates, not calibrated win percentages. '
            'The model assumes immediate claims at threefold repetition or 50 moves; '
            'repetition history begins at the supplied starting position.';

  Widget _searchSection() {
    final isBook = _buildMode == BuildMode.chessDbBook;
    return _cardSection(isBook ? 'Book size' : 'Search', [
      if (_buildMode == BuildMode.stockfishExpectimax)
        SegmentedButton<SearchAlgorithm>(
          key: const ValueKey('generation-search-method'),
          segments: const [
            ButtonSegment(value: SearchAlgorithm.pure, label: Text('Pure')),
            ButtonSegment(
              value: SearchAlgorithm.rolling,
              label: Text('Fast · 4-ply'),
            ),
          ],
          selected: {_searchAlgorithm},
          onSelectionChanged: (value) {
            if (!mounted) return;
            setState(() => _searchAlgorithm = value.first);
          },
        ),
      if (_buildMode == BuildMode.stockfishExpectimax)
        _caption(_searchAlgorithmCaption()),
      if (isBook)
        _caption(
          'Depths count half-moves from the current board. Branching stops first; '
          'each line then continues to the line limit, or until ChessDB runs out. '
          'Starting moves are included in the exported PGN. A FEN alone keeps its setup position.',
        ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _maxPlyCtrl,
            isBook
                ? 'Branching depth (half-moves)'
                : 'Max line length (half-moves)',
            defaultText: '4',
            onEdited: () => setState(() {}),
            tooltip: isBook
                ? 'Stop adding opponent branches at this depth.'
                : 'How deep lines are allowed to grow.',
          ),
          if (isBook) ...[
            _numField(
              _bookTailMaxPlyCtrl,
              'Line limit (half-moves)',
              onEdited: () => setState(() {}),
              tooltip:
                  'Total length from the build position, including the branching portion. Never shorter than the branching depth.',
            ),
            _numField(
              _oppMaxChildrenCtrl,
              'Opponent replies per position',
              onEdited: () => setState(() {}),
              tooltip:
                  'Limit replies after the root. The root includes every qualifying master reply to cover the opening systems.',
            ),
            _numField(
              _oppMassTargetCtrl,
              'Reply coverage (0–1)',
              onEdited: () => setState(() {}),
              tooltip:
                  'Share of master-game replies to cover at each position, subject to the reply limit. This is not a guarantee of overall repertoire coverage.',
            ),
          ],
          _numField(
            _timeBudgetCtrl,
            'Stop after (minutes)',
            defaultText: '0',
            onEdited: () => setState(() {}),
            tooltip:
                '0 = no limit. An in-flight evaluation may finish after this limit. '
                'Search stops between atomic expansions and marks the search incomplete. '
                'It can be resumed. Output enrichment is outside this budget.',
          ),
        ],
      ),
    ]);
  }

  // ── Output ──────────────────────────────────────────────────────────────

  Widget _outputSection() {
    final isDb = _buildMode == BuildMode.dbExplorer;
    return _cardSection('What to build', leadingRule: false, [
      ChoiceField<BuildMode>(
        label: 'Build from',
        value: _buildMode,
        enabled: !widget.isGenerating,
        style: const TextStyle(fontSize: 13),
        items: const [
          ChoiceItem(
            value: BuildMode.stockfishExpectimax,
            label: 'Engine + human model (recommended)',
          ),
          ChoiceItem(
            value: BuildMode.maiaDbExplore,
            label: 'Database win rates (no engine)',
          ),
          ChoiceItem(
            value: BuildMode.chessDbBook,
            label: 'ChessDB mainline book',
          ),
          ChoiceItem(value: BuildMode.dbExplorer, label: 'My PGN files'),
        ],
        onChanged: (v) {
          setState(() {
            _buildMode = v;
            // A book spanning the whole encyclopedia wants chapters
            // cut by code, not by where it happens to branch. Set
            // here rather than derived from the mode so the checkbox
            // shows what will happen and can be turned back off.
            if (v == BuildMode.chessDbBook) _chaptersByEco = true;
          });
        },
      ),
      _caption(_buildModeDescription()),
      if (_buildMode == BuildMode.chessDbBook)
        TextButton.icon(
          key: const ValueKey('chessdb-starter-settings'),
          onPressed: widget.isGenerating ? null : _applyChessDbPreset,
          icon: const Icon(Icons.menu_book_outlined, size: 16),
          label: const Text('Use compact repertoire settings'),
        ),
      const SizedBox(height: 8),
      _labeledCheckbox(
        'Only traps',
        _trapsOnly,
        (v) => setState(() => _trapsOnly = v),
        tooltip:
            'Exports only the lines that run through a trap — a position where '
            'the opponent has a tempting move that loses. The search is '
            'unchanged; you get a trap collection, not a repertoire.',
      ),
      // The picker used to sit here greyed out at 45% opacity whatever the
      // build source was — a dead half-screen of UI for the three sources
      // that never read it. Now it is simply absent outside DB Explorer: the
      // attached files live in _pgnSources, so a trip through another build
      // source and back still finds them.
      if (isDb) ...[
        const SizedBox(height: 8),
        _caption('PGN files used for this build:'),
        const SizedBox(height: 4),
        PgnSourcesPanel(controller: _pgnSources),
      ],
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

  void _applyChessDbPreset() {
    setState(() {
      _applyInitialConfig(
        chessDbRepertoirePreset(playAsWhite: widget.playAsWhite),
      );
    });
  }

  void _resetToDefaults() {
    setState(() {
      _applyInitialConfig(
        TreeBuildConfig.formDefaults(
          startFen: '',
          playAsWhite: widget.playAsWhite,
        ),
      );
    });
    showAppSnackBar(context, 'Settings reset to defaults');
  }

  Future<void> _saveCurrentAsPreset() async {
    final name = await showNameEntryDialog(
      context,
      title: 'Save settings as preset',
      fieldLabel: 'Preset name',
      confirmLabel: 'Save',
      allowUnchanged: true,
    );
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
        if (_showSkeleton)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SkeletonPlanCard(
              controller: _skeleton,
              playAsWhite: widget.playAsWhite,
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
          case '::chessdb':
            _applyChessDbPreset();
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
        const PopupMenuItem(
          value: '::chessdb',
          child: Text('ChessDB compact repertoire'),
        ),
        const PopupMenuDivider(),
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
    final depth = BulkAnalysisSettings.instance.depth;
    final budget = int.tryParse(_timeBudgetCtrl.text.trim()) ?? 0;
    if (_buildMode == BuildMode.chessDbBook) {
      final tail = int.tryParse(_bookTailMaxPlyCtrl.text.trim()) ?? 40;
      return [
        widget.playAsWhite ? 'As White' : 'As Black',
        'ChessDB best moves',
        _useMasterGames ? 'master replies' : 'single mainline',
        'branch for $ply half-moves',
        'continue to ${tail < ply ? ply : tail}',
        if (_bookEngineFallback) 'Stockfish on database misses',
        if ((_seedConfig?.maxNodes ?? 0) > 0)
          '${_seedConfig!.maxNodes} nodes maximum',
        if (budget > 0) 'build budget ${budget}m',
      ].join(' · ');
    }
    final source = switch (_buildMode) {
      BuildMode.stockfishExpectimax => 'Stockfish + Maia',
      BuildMode.maiaDbExplore => 'database win rates',
      BuildMode.dbExplorer => 'your PGN files',
      BuildMode.chessDbBook => 'ChessDB mainlines',
    };
    final parts = [
      // Whose repertoire this is decides every move in it, so it leads.
      widget.playAsWhite ? 'As White' : 'As Black',
      _searchAlgorithm == SearchAlgorithm.rolling
          ? 'Fast (4-ply, approximate)'
          : 'Pure search',
      _buildMode != BuildMode.stockfishExpectimax && _useMasterGames
          ? 'master practice, Maia $elo off-book'
          : 'Maia $elo throughout',
      source,
      '$ply half-moves deep',
      if (_usesEngineDepth) 'engine depth $depth',
      'expected-score objective',
      if (_trapsOnly) 'traps only',
      if (_buildMode != BuildMode.stockfishExpectimax &&
          _verifyFinal &&
          !_noVerifyMode)
        're-evaluated',
      if (budget > 0) 'stops after ${budget}m',
    ];
    return parts.join(' · ');
  }

  Widget _summary() {
    return Tooltip(
      message:
          'What this build will do. Engine-loss limits and resource settings '
          'are under Advanced…',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceInset,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_summaryText(), style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
