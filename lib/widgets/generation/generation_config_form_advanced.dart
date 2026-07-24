part of 'generation_config_form.dart';

/// Card-level projection of the novelty/memorability pair: two opposing
/// preferences presented as one three-way choice so they can never both be
/// on.
enum _MovePreference { novel, neutral, natural }

/// The advanced gear dialog: every knob, grouped by concept, with
/// spelled-out labels, visible defaults, and disabled-with-reason for
/// controls the current configuration makes inert.
///
/// All values live in the form state (controllers and fields), so closing
/// the dialog loses nothing and the Layer-1 card stays in sync.  Only
/// [EvalSourcesSection] is NOT here — its widget state is read through a
/// GlobalKey at build time, so it must stay mounted in the main tree.
mixin _GenerationConfigAdvanced
    on
        _GenerationConfigFormStateBase,
        _GenerationConfigDescriptions,
        _GenerationConfigFields {
  _MovePreference get _movePreference {
    if (_preferNovelties) return _MovePreference.novel;
    final memTol = int.tryParse(_memorabilityToleranceCtrl.text.trim()) ?? 0;
    return memTol > 0 ? _MovePreference.natural : _MovePreference.neutral;
  }

  void _applyMovePreference(_MovePreference pref) {
    switch (pref) {
      case _MovePreference.novel:
        _preferNovelties = true;
        _memorabilityToleranceCtrl.text = '0';
      case _MovePreference.neutral:
        _preferNovelties = false;
        _memorabilityToleranceCtrl.text = '0';
      case _MovePreference.natural:
        _preferNovelties = false;
        final memTol =
            int.tryParse(_memorabilityToleranceCtrl.text.trim()) ?? 0;
        if (memTol <= 0) _memorabilityToleranceCtrl.text = '25';
    }
  }

  Future<void> _openAdvancedDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          void refresh() => setDialog(() {});
          return Dialog(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 660,
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                    child: Row(
                      children: [
                        Text(
                          'Advanced generation settings',
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ..._opponentModelSection(refresh),
                          ..._moveChoiceSection(refresh),
                          ..._searchBudgetSection(refresh),
                          ..._verificationSection(refresh),
                          ..._exportSection(refresh),
                          if (_buildMode == BuildMode.dbExplorer)
                            ..._pgnFilterSection(refresh),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    // The card's segments/summary project these values — repaint them.
    if (mounted) setState(() {});
  }

  List<Widget> _opponentModelSection(VoidCallback refresh) {
    final dbActive = _lichessDbOverride != null;
    return [
      _sectionHeader('Opponent model'),
      Row(
        children: [
          const Text('Move frequencies from', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Maia (neural)'),
            selected: !dbActive,
            onSelected: widget.isGenerating
                ? null
                : (_) {
                    _lichessDbOverride = null;
                    refresh();
                  },
          ),
          const SizedBox(width: 4),
          ChoiceChip(
            label: const Text('Lichess database'),
            selected: dbActive,
            onSelected: widget.isGenerating
                ? null
                : (_) {
                    _lichessDbOverride ??= LichessDatabase.lichess;
                    refresh();
                  },
          ),
          const LichessDbInfoIcon(size: 14),
        ],
      ),
      _caption(
        'Maia predicts human moves at the target rating. The Lichess '
        'database uses real game frequencies, with Maia as fallback for '
        'uncovered positions.',
      ),
      if (dbActive) ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: LichessDbSelector(
            database: _lichessDbOverride!,
            onDatabaseChanged: (db) {
              final wasMasters = _lichessDbOverride == LichessDatabase.masters;
              final isMasters = db == LichessDatabase.masters;
              _lichessDbOverride = db;
              if (wasMasters != isMasters) {
                _lichessMinGamesCtrl.text = isMasters ? '4' : '10';
              }
              refresh();
            },
            selectedSpeeds: _lichessSpeeds,
            onSpeedsChanged: (s) {
              _lichessSpeeds
                ..clear()
                ..addAll(s);
              refresh();
            },
            selectedRatings: _lichessRatings,
            onRatingsChanged: (r) {
              _lichessRatings
                ..clear()
                ..addAll(r);
              refresh();
            },
            minGamesController: _lichessMinGamesCtrl,
            enabled: !widget.isGenerating,
            compact: true,
          ),
        ),
      ],
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _maiaEloCtrl,
            'Opponent rating (Elo)',
            defaultText: '2200',
            onEdited: refresh,
            tooltip:
                'Rating Maia models the opponent at. The card\'s '
                'Opponent-strength slider edits this same value.',
          ),
          _numField(
            _oppPolicyTempCtrl,
            'Opponent temperature',
            defaultText: '1.0',
            onEdited: refresh,
            tooltip:
                '1.0 = Maia as-is. Above 1.0 flattens the move '
                'distribution (a sloppier, more varied pool); below 1.0 '
                'sharpens it toward the most common reply.',
          ),
          _numField(
            _maiaPriorGamesCtrl,
            'Blend with Maia (virtual games)',
            defaultText: '30',
            onEdited: refresh,
            enabled: dbActive,
            disabledReason: 'Needs the Lichess database source',
            tooltip:
                'Dirichlet prior weight: database counts are blended with '
                'Maia as if Maia contributed this many games. Sparse '
                'positions lean on Maia; well-covered ones on real data. '
                '0 disables.',
          ),
          _numField(
            _oppMaxChildrenCtrl,
            'Opponent replies per position',
            defaultText: '4',
            onEdited: refresh,
            tooltip: 'Maximum opponent replies explored at each position.',
          ),
          _numField(
            _oppMassTargetCtrl,
            'Reply coverage target (0–1)',
            defaultText: '0.80',
            onEdited: refresh,
            tooltip:
                'Stop adding opponent replies once this share of their '
                'games is covered.',
          ),
          _numField(
            _coverMinProbCtrl,
            'Always answer replies above (0–1)',
            defaultText: '0.05',
            onEdited: refresh,
            tooltip:
                'No-silent-holes floor: any reply at least this likely '
                'gets a repertoire answer even when other budgets would '
                'skip it. 0 disables.',
          ),
          _numField(
            _cutoffCtrl,
            'Ignore lines rarer than (%)',
            defaultText: '0.01',
            onEdited: refresh,
            tooltip:
                'Lines whose cumulative reach probability falls below this '
                'percentage stop being explored.',
          ),
        ],
      ),
    ];
  }

  List<Widget> _moveChoiceSection(VoidCallback refresh) {
    final isTrappy = _selectionMode == SelectionMode.trappy;
    final pref = _movePreference;
    final hasSetup = _setupMovesCtrl.text.trim().isNotEmpty;
    return [
      _sectionHeader('Move choice'),
      DropdownButtonFormField<SelectionMode>(
        initialValue: _selectionMode,
        decoration: const InputDecoration(
          labelText: 'Line selection',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final mode in SelectionMode.values)
            DropdownMenuItem(
              value: mode,
              child: Text(_selectionModeLabel(mode)),
            ),
        ],
        onChanged: widget.isGenerating
            ? null
            : (v) {
                if (v != null) {
                  _selectionMode = v;
                  refresh();
                }
              },
      ),
      _caption(_selectionModeDescription()),
      const SizedBox(height: 12),
      Row(
        children: [
          const Text('Prefer', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          SegmentedButton<_MovePreference>(
            segments: const [
              ButtonSegment(
                value: _MovePreference.novel,
                label: Text('Novel moves', style: TextStyle(fontSize: 12)),
                tooltip:
                    'Boost sound-but-rare moves so opponents leave their '
                    'preparation.',
              ),
              ButtonSegment(
                value: _MovePreference.neutral,
                label: Text('Neutral', style: TextStyle(fontSize: 12)),
                tooltip: 'No popularity preference.',
              ),
              ButtonSegment(
                value: _MovePreference.natural,
                label: Text('Natural moves', style: TextStyle(fontSize: 12)),
                tooltip:
                    'Within a small eval tolerance, pick the move you\'d '
                    'play anyway — easier to memorize.',
              ),
            ],
            selected: {pref},
            showSelectedIcon: false,
            onSelectionChanged: widget.isGenerating
                ? null
                : (sel) {
                    _applyMovePreference(sel.first);
                    refresh();
                  },
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _memorabilityToleranceCtrl,
            'Natural-move tolerance (cp)',
            defaultText: '0',
            onEdited: refresh,
            enabled: pref == _MovePreference.natural && !isTrappy,
            disabledReason: isTrappy
                ? 'Ignored in Trappy selection'
                : 'Only with Prefer: Natural moves',
            tooltip:
                'A natural move may lose up to this many centipawns vs the '
                'best candidate and still be picked.',
          ),
          _numField(
            _setupToleranceCtrl,
            'Setup tolerance (cp)',
            defaultText: '30',
            onEdited: refresh,
            enabled: hasSetup,
            disabledReason: 'Set system moves in the Style row first',
            tooltip:
                'A preferred-setup move may lose up to this many '
                'centipawns vs the best candidate and still be chosen.',
          ),
          _numField(
            _evalGuardCtrl,
            'Max eval loss vs best (cp)',
            defaultText: '30',
            onEdited: refresh,
            tooltip:
                'Hard guard: no repertoire move may lose more than this '
                'against the best sibling. Trappy mode widens it to at '
                'least 100.',
          ),
          _numField(
            _minEvalCtrl,
            'Min eval for us (cp)',
            defaultText: widget.playAsWhite ? '0' : '-100',
            onEdited: refresh,
            tooltip:
                'Lines evaluated below this (for us) are abandoned as '
                'lost causes.',
          ),
          _numField(
            _maxEvalCtrl,
            'Max eval for us (cp)',
            defaultText: widget.playAsWhite ? '200' : '100',
            onEdited: refresh,
            tooltip:
                'Lines evaluated above this are abandoned as already '
                'winning — no need to memorize conversions.',
          ),
          _numField(
            _leafConfidenceCtrl,
            'Leaf eval confidence (0–1)',
            defaultText: '1.0',
            onEdited: refresh,
            tooltip:
                'Trust in the engine eval at unexplored leaves; lower '
                'values blend toward an even game.',
          ),
        ],
      ),
      const SizedBox(height: 4),
      _toggleSwitch(
        'Eval limits relative to starting position',
        _relativeEval,
        (v) {
          _relativeEval = v;
          refresh();
        },
        tooltip:
            'On: min/max eval are measured relative to the starting '
            'position\'s eval. Off: absolute centipawn limits.',
      ),
    ];
  }

  List<Widget> _searchBudgetSection(VoidCallback refresh) {
    final isEngine = _buildMode == BuildMode.stockfishExpectimax;
    final isPure = _searchAlgorithm == SearchAlgorithm.pure;
    final isTrappy = _selectionMode == SelectionMode.trappy;
    return [
      _sectionHeader('Search budget'),
      Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          _labeledCheckbox(
            'Exhaustive search (much slower)',
            isPure,
            (v) {
              _searchAlgorithm = v
                  ? SearchAlgorithm.pure
                  : SearchAlgorithm.fast;
              refresh();
            },
            tooltip:
                'Off (recommended): best-first search that spends less '
                'effort on rare lines, with the coverage floor still '
                'guaranteed. On: full-width search everywhere.',
          ),
          _labeledCheckbox(
            'Wide opening search',
            _wideOpening,
            (v) {
              _wideOpening = v;
              refresh();
            },
            tooltip:
                'Explore extra candidates for the first few of our moves, '
                'then narrow. Catches alternatives and novelties at the '
                'cost of some build time.',
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _maxPlyCtrl,
            'Max depth (half-moves)',
            defaultText: '20',
            onEdited: refresh,
            tooltip: 'How deep lines may grow. The Effort presets set this.',
          ),
          _numField(
            _engineDepthCtrl,
            'Engine depth per position',
            defaultText: '$kDefaultGenerationEvalDepth',
            onEdited: refresh,
            enabled: isEngine,
            disabledReason: 'Engine is not used by this build source',
            tooltip:
                'Stockfish search depth for every evaluated position. '
                'The Effort presets set this.',
          ),
          _numField(
            _multipvCtrl,
            'Candidate moves per position',
            defaultText: '4',
            onEdited: refresh,
            enabled: isEngine,
            disabledReason: 'Engine is not used by this build source',
            tooltip:
                'How many of our candidate moves Stockfish evaluates at '
                'each position (MultiPV).',
          ),
          _numField(
            _ourAltDiscountCtrl,
            'Alternative budget share (0–1)',
            defaultText: '0.25',
            onEdited: refresh,
            enabled: !isPure,
            disabledReason: 'Best-first search only',
            tooltip:
                'Search-priority multiplier for our non-best candidates. '
                'Lower = more budget on the main line.',
          ),
          _numField(
            _fastAltGapCtrl,
            'Skip alternatives behind by (cp)',
            defaultText: '30',
            onEdited: refresh,
            enabled: !isPure && !isTrappy,
            disabledReason: isPure
                ? 'Best-first search only'
                : 'Ignored in Trappy selection',
            tooltip:
                'Our alternatives more than this far behind the best '
                'candidate stay evaluated leaves instead of growing '
                'subtrees. 0 disables.',
          ),
        ],
      ),
      const SizedBox(height: 12),
      EngineResourcesSection(
        threadsController: _engineThreadsCtrl,
        isGenerating: widget.isGenerating,
        isDbExplorer: _buildMode == BuildMode.dbExplorer,
      ),
    ];
  }

  List<Widget> _verificationSection(VoidCallback refresh) {
    return [
      _sectionHeader('Verification'),
      Row(
        children: [
          _toggleSwitch(
            'Verify final repertoire',
            _verifyFinal,
            (v) {
              _verifyFinal = v;
              refresh();
            },
            tooltip:
                'Re-check every selected move at a deeper engine depth '
                'after selection and replace the ones that fail. Slower, '
                'but the export carries a depth guarantee.',
          ),
          const SizedBox(width: 16),
          _numField(
            _verifyDepthCtrl,
            'Verification depth (0 = auto)',
            defaultText: '0',
            onEdited: refresh,
            enabled: _verifyFinal,
            disabledReason: 'Verification is off',
            tooltip:
                'Engine depth for the verification pass. 0 = automatic '
                '(engine depth + 6, at least 20).',
          ),
        ],
      ),
    ];
  }

  List<Widget> _exportSection(VoidCallback refresh) {
    return [
      _sectionHeader('PGN export'),
      _numField(
        _targetLinesCtrl,
        'Max unique lines (0 = keep all)',
        defaultText: '100',
        onEdited: refresh,
        tooltip:
            'Similar lines (same moves by us, different opponent moves) '
            'collapse to one representative; the survivors teach the most '
            'new, likely, sharp moves — up to this many.',
      ),
      const SizedBox(height: 4),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text(
          'Order lines by how likely you are to face them',
          style: TextStyle(fontSize: 13),
        ),
        value: _rankLinesByImportance,
        onChanged: widget.isGenerating
            ? null
            : (v) {
                _rankLinesByImportance = v;
                refresh();
              },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text(
          'Annotate opponent-move probabilities',
          style: TextStyle(fontSize: 13),
        ),
        value: _annotateMoveProbabilities,
        onChanged: widget.isGenerating
            ? null
            : (v) {
                _annotateMoveProbabilities = v;
                refresh();
              },
      ),
      if (_annotateMoveProbabilities)
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: DropdownButtonFormField<bool>(
            initialValue: _annotateMaiaOnly,
            decoration: const InputDecoration(
              labelText: 'Probability source',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: true, child: Text('Maia only')),
              DropdownMenuItem(
                value: false,
                child: Text('Lichess database + Maia fallback'),
              ),
            ],
            onChanged: widget.isGenerating
                ? null
                : (v) {
                    if (v != null) {
                      _annotateMaiaOnly = v;
                      refresh();
                    }
                  },
          ),
        ),
    ];
  }

  List<Widget> _pgnFilterSection(VoidCallback refresh) {
    return [
      _sectionHeader('PGN source filters'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _dbMinGamesCtrl,
            'Min games per move',
            defaultText: '5',
            onEdited: refresh,
            tooltip:
                'Opponent moves need at least this many games in your PGN '
                'files to be explored.',
          ),
          _numField(
            _dbMinProbCtrl,
            'Min move probability (0–1)',
            defaultText: '0.05',
            onEdited: refresh,
            tooltip: 'Minimum move frequency to include an opponent reply.',
          ),
          _numField(
            _minEloCtrl,
            'Min player Elo (0 = off)',
            defaultText: '0',
            onEdited: refresh,
            tooltip: 'Skip games where both players are below this rating.',
          ),
        ],
      ),
    ];
  }
}
