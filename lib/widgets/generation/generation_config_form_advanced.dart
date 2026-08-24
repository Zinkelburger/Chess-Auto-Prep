part of 'generation_config_form.dart';

/// The advanced gear dialog's *content*: the knobs themselves, grouped into
/// the sections the dialog arranges. Knobs shown on the main form are NOT
/// repeated here.
///
/// All values live in the form state (controllers and fields), so closing
/// the dialog loses nothing and the main form stays in sync.  Only
/// [EvalSourcesSection] is NOT here — its widget state is read through a
/// GlobalKey at build time, so it must stay mounted in the main tree.
///
/// The dialog chrome (layout, table of contents, section cards) is
/// [AdvancedSettingsDialog], which knows nothing about generation and can be
/// tested on its own.
mixin _GenerationConfigAdvanced
    on
        _GenerationConfigFormStateBase,
        _GenerationConfigDescriptions,
        _GenerationConfigFields {
  Future<void> _openAdvancedDialog() async {
    await AdvancedSettingsDialog.show(
      context,
      sections: [
        AdvancedSection(
          'Opponent model',
          Icons.person_outline,
          _opponentModelSection,
        ),
        AdvancedSection('Move choice', Icons.alt_route, _moveChoiceSection),
        AdvancedSection('Search tuning', Icons.tune, _searchBudgetSection),
        AdvancedSection(
          'Verification',
          Icons.verified_outlined,
          _verificationSection,
        ),
        AdvancedSection(
          'PGN export',
          Icons.description_outlined,
          _exportSection,
        ),
        AdvancedSection(
          'PGN source filters',
          Icons.filter_alt_outlined,
          _pgnFilterSection,
        ),
      ],
    );
    // The main form's summary projects these values — repaint it.
    if (mounted) setState(() {});
  }

  List<Widget> _opponentModelSection(VoidCallback refresh) {
    return [
      _caption(
        _buildMode == BuildMode.dbExplorer
            ? 'Opponent replies come from move frequencies in your PGN '
                  'files, blended with Maia where the database is thin.'
            : 'Opponent replies come from Maia, which predicts human moves '
                  'at the rating you set. To model real opponents from real '
                  'games, switch the build source to a PGN database.',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
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
            enabled: _buildMode == BuildMode.dbExplorer,
            disabledReason: 'Needs a PGN database as the build source',
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

  /// How the build chooses our move: the selection algorithm, the forced
  /// setup moves, and the window a candidate has to fall inside.
  List<Widget> _moveChoiceSection(VoidCallback refresh) => [
    ..._moveChoiceModeField(refresh),
    ..._moveChoiceSetupField(refresh),
    ..._moveChoiceWindowFields(refresh),
    ..._moveChoiceRelativeEvalField(refresh),
  ];

  /// Which algorithm picks our move at each of our turns.
  List<Widget> _moveChoiceModeField(VoidCallback refresh) {
    return [
      DropdownButtonFormField<SelectionMode>(
        initialValue: _selectionMode,
        decoration: const InputDecoration(
          labelText: 'How the repertoire move is picked',
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
    ];
  }

  /// Forced opening moves — the setup the build must play out before its
  /// own choices begin.
  List<Widget> _moveChoiceSetupField(VoidCallback refresh) {
    return [
      const SizedBox(height: 12),
      TextField(
        controller: _setupMovesCtrl,
        enabled: !widget.isGenerating,
        onChanged: (_) => refresh(),
        decoration: const InputDecoration(
          labelText: 'Preferred setup moves (SAN, any order)',
          hintText: 'e.g. Be3 Qd2 f3 O-O-O h4 Nh3',
          helperText:
              'Played whenever they stay sound; the repertoire deviates '
              'automatically when the opponent makes them too costly. '
              'Leave empty for no preference.',
          helperMaxLines: 3,
          isDense: true,
          border: OutlineInputBorder(),
        ),
        style: const TextStyle(fontSize: 13),
      ),
    ];
  }

  /// The eval window and the practical-play knobs that decide which
  /// candidate moves survive.
  List<Widget> _moveChoiceWindowFields(VoidCallback refresh) {
    // Trappy selection and a forced setup each disable knobs below.
    final isTrappy = _selectionMode == SelectionMode.trappy;
    final hasSetup = _setupMovesCtrl.text.trim().isNotEmpty;
    return [
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _memorabilityToleranceCtrl,
            'Natural-move tolerance (cp)',
            defaultText: '0',
            onEdited: refresh,
            enabled: !isTrappy && !_preferNovelties,
            disabledReason: _preferNovelties
                ? 'Ignored while "Prefer novelties" is on — they pull '
                      'opposite ways'
                : 'Ignored when maximizing opponent mistakes',
            tooltip:
                'Above 0, a move you would play anyway may lose up to this '
                'many centipawns against the best candidate and still be '
                'picked, because it is easier to remember. Pulls against '
                '"Prefer novelties".',
          ),
          _numField(
            _setupToleranceCtrl,
            'Setup tolerance (cp)',
            defaultText: '30',
            onEdited: refresh,
            enabled: hasSetup,
            disabledReason: 'Enter preferred setup moves first',
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
                'against the best sibling. Maximize-mistakes widens it to '
                'at least 100.',
          ),
          _numField(
            _minEvalCtrl,
            _relativeEval ? 'Floor, vs. start (cp)' : 'Min eval for us (cp)',
            defaultText: _relativeEval ? '-100' : '0',
            onEdited: refresh,
            tooltip: _relativeEval
                ? 'How much worse than the starting position you will still '
                      'prepare.\nThe floor moves with the root: at a root of '
                      '0.00 a value of -100 floors\nat -1.00, and at a root of '
                      '+0.60 the same value floors at -0.40. One\nsetting, '
                      'whatever position you hand the builder.\n\n'
                      'This judges positions *you* chose to enter. A position '
                      'the opponent\nforces on you is never dropped for being '
                      'bad — you need an answer\nmost precisely when you are '
                      'worse.\n\n0 means "never accept anything worse than '
                      'the start", which rules out\nnormal opening play and '
                      'every gambit.'
                : 'Lines evaluated below this (for us) are abandoned as '
                      'lost causes.',
          ),
          _numField(
            _maxEvalCtrl,
            _relativeEval ? 'Ceiling, vs. start (cp)' : 'Max eval for us (cp)',
            defaultText: _relativeEval
                ? '200'
                : (widget.playAsWhite ? '200' : '100'),
            onEdited: refresh,
            tooltip: _relativeEval
                ? 'How much better than the starting position is far enough. '
                      'Past this the\nline stops as already winning — no need '
                      'to memorise conversions. Measured\nfrom the root the '
                      'same way the floor is.'
                : 'Lines evaluated above this are abandoned as already '
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
    ];
  }

  /// Whether the eval limits are read against the starting position rather
  /// than against absolute zero.
  List<Widget> _moveChoiceRelativeEvalField(VoidCallback refresh) {
    return [
      _labeledCheckbox(
        'Eval limits relative to starting position',
        _relativeEval,
        (v) {
          _relativeEval = v;
          refresh();
        },
        tooltip:
            'On (recommended): the two limits above are offsets from the '
            'root position\'s\nown eval, so the same numbers mean the same '
            'thing whatever position you\nbuild from. Off: they are absolute '
            'centipawn scores, and you have to\nre-pick them per position and '
            'per colour.',
      ),
    ];
  }

  List<Widget> _searchBudgetSection(VoidCallback refresh) {
    final isPure = _searchAlgorithm == SearchAlgorithm.pure;
    final isTrappy = _selectionMode == SelectionMode.trappy;
    final isDb = _buildMode == BuildMode.dbExplorer;
    return [
      Text(
        isPure
            ? 'Pure search is selected on the main form — these '
                  'Fast-only narrowing knobs are ignored.'
            : 'Fast search is selected on the main form. These control '
                  'how much it narrows rarely-reached lines.',
        style: AppTextStyles.caption.copyWith(fontSize: 11),
      ),
      const SizedBox(height: 10),
      _labeledCheckbox(
        'Wide opening search',
        _wideOpening,
        (v) {
          _wideOpening = v;
          refresh();
        },
        tooltip:
            'Explore extra candidates for the first few of your moves, '
            'then narrow. Catches alternatives and novelties at the cost '
            'of some build time.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _ourAltDiscountCtrl,
            'Alternative budget share (0–1)',
            defaultText: '0.25',
            onEdited: refresh,
            enabled: !isPure && !isDb,
            disabledReason: isDb
                ? 'Your PGN files decide which lines grow in this mode'
                : 'Fast search only',
            tooltip:
                'Search-priority multiplier for your non-best candidates. '
                'Lower = more budget on the main line.',
          ),
          _numField(
            _fastAltGapCtrl,
            'Skip alternatives behind by (cp)',
            defaultText: '30',
            onEdited: refresh,
            enabled: !isPure && !isTrappy && !isDb,
            disabledReason: isDb
                ? 'Your PGN files decide which lines grow in this mode'
                : isPure
                ? 'Fast search only'
                : 'Ignored when maximizing opponent mistakes',
            tooltip:
                'Your alternatives more than this far behind the best '
                'candidate stay evaluated leaves instead of growing '
                'subtrees. 0 disables.',
          ),
        ],
      ),
      const SizedBox(height: 12),
      EngineResourcesSection(
        threadsController: _engineThreadsCtrl,
        isGenerating: widget.isGenerating,
        isDbExplorer: isDb,
        enabled:
            _buildMode == BuildMode.stockfishExpectimax ||
            _buildMode == BuildMode.dbExplorer,
      ),
    ];
  }

  List<Widget> _verificationSection(VoidCallback refresh) {
    final noVerify = _buildMode == BuildMode.maiaDbExplore;
    return [
      _labeledCheckbox(
        'Verify final repertoire',
        _verifyFinal,
        (v) {
          _verifyFinal = v;
          refresh();
        },
        enabled: !noVerify,
        disabledReason: 'Verification never runs in this build source',
        tooltip:
            'Re-check every selected move at a deeper engine depth '
            'after selection and replace the ones that fail. Slower, '
            'but the export carries a depth guarantee.',
      ),
      const SizedBox(height: 8),
      _numField(
        _verifyDepthCtrl,
        'Verification depth (0 = auto)',
        defaultText: '0',
        onEdited: refresh,
        enabled: _verifyFinal && !noVerify,
        disabledReason: noVerify
            ? 'Verification never runs in this build source'
            : 'Verification is off',
        tooltip:
            'Engine depth for the verification pass. 0 = automatic '
            '(engine depth + 6, at least 20).',
      ),
    ];
  }

  /// Everything that shapes the exported PGN.
  ///
  /// Five unrelated domains used to share one 257-line list literal.
  /// They are still presented as one section — the reader thinks of them
  /// together as "what comes out" — but each is now edited on its own.
  List<Widget> _exportSection(VoidCallback refresh) => [
    ..._exportCoverageFields(refresh),
    ..._exportChapterFields(refresh),
    ..._exportMasterGameFields(refresh),
    ..._exportRefutationFields(refresh),
    ..._exportAlternativeFields(refresh),
  ];

  /// How much of the tree reaches the PGN: the coverage target, engine
  /// continuations for lines the ply cap cut off, and line order.
  List<Widget> _exportCoverageFields(VoidCallback refresh) {
    return [
      _numField(
        _lineCoverageCtrl,
        'Coverage target %',
        defaultText: '92',
        onEdited: refresh,
        tooltip:
            'How much of what you will actually face the exported lines '
            'should cover.\nLines are kept in order of how much new ground '
            'each one breaks — a position\nyou reach and the move you play '
            'there — and the export stops once this\nshare of the reachable '
            'probability is covered. Lines that only repeat\ndecisions '
            'already covered, including ones that transpose in from another\n'
            'move order, are never kept at any setting.\n\n'
            '100% keeps everything that teaches anything new. The last few '
            'percent\ncost the most lines: on a real Benko tree 92% was 300 '
            'lines and 100%\nwas 530, the extra ones splitting hairs at move '
            '14.',
      ),
      const SizedBox(height: 8),
      _numField(
        _engineTailCtrl,
        'Engine continuation plies (0 = off)',
        defaultText: '6',
        onEdited: refresh,
        tooltip:
            'A line that stops because the build hit its ply cap ends mid-'
            'position.\nThis walks the final position with the engine at the '
            'verification depth\nand appends that many plies of best play to '
            'the line.\n\nThe appended moves are part of the line and get '
            'trained with the rest.\nThey are engine best play rather than '
            'moves selection vouched for, so the\nfirst one carries a note '
            'in the PGN saying where preparation stopped.',
      ),
      const SizedBox(height: 8),
      _numField(
        _targetLinesCtrl,
        'Hard cap on lines (0 = no cap)',
        defaultText: '0',
        onEdited: refresh,
        tooltip:
            'Stops the export at this many lines even if the coverage target '
            'is not met.\nLeave at 0 and let coverage decide.',
      ),
      const SizedBox(height: 4),
      _labeledCheckbox(
        'Order lines by how likely you are to face them',
        _rankLinesByImportance,
        (v) {
          _rankLinesByImportance = v;
          refresh();
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<MoveAnnotationDetail>(
        initialValue: _annotationDetail,
        decoration: const InputDecoration(
          labelText: 'Per-move annotations',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: const [
          DropdownMenuItem(
            value: MoveAnnotationDetail.none,
            child: Text('None — moves only'),
          ),
          DropdownMenuItem(
            value: MoveAnnotationDetail.likelihood,
            child: Text('Reply likelihood'),
          ),
          DropdownMenuItem(
            value: MoveAnnotationDetail.full,
            child: Text('Full — eval, ease, scores'),
          ),
        ],
        onChanged: widget.isGenerating
            ? null
            : (v) {
                if (v == null) return;
                _annotationDetail = v;
                refresh();
              },
      ),
      _caption(
        'Full writes the numbers the build already computed — evaluation, '
        'how hard each move is to find, and how the move scores in real '
        'games — next to every move.',
      ),
    ];
  }

  /// Whether the export is one flat list or named chapters cut at branch
  /// points, and how those chapters are sized.
  List<Widget> _exportChapterFields(VoidCallback refresh) {
    return [
      const SizedBox(height: 12),
      _labeledCheckbox(
        'Group lines into named chapters',
        _organizeIntoChapters,
        (v) {
          _organizeIntoChapters = v;
          refresh();
        },
        tooltip:
            'Cuts the export at the branch points where your repertoire '
            'divides and names each chapter from the opening database, the '
            'way a published course is laid out.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _maxLinesPerChapterCtrl,
            'Max lines per chapter',
            defaultText: '40',
            onEdited: refresh,
            enabled: _organizeIntoChapters,
            disabledReason: 'Chapters are off',
            tooltip:
                'A chapter bigger than this is split again at its next '
                'branch point.',
          ),
          _numField(
            _minLinesPerChapterCtrl,
            'Min lines per chapter',
            defaultText: '5',
            onEdited: refresh,
            enabled: _organizeIntoChapters,
            disabledReason: 'Chapters are off',
            tooltip:
                'Branches smaller than this are collected into a single '
                '"Rare sidelines" chapter instead of getting one each.',
          ),
          _numField(
            _modelGameCountCtrl,
            'Model games',
            defaultText: '6',
            onEdited: refresh,
            tooltip:
                'Strong games that follow this repertoire out of the '
                'opening, appended as a final chapter — from your PGN '
                'database when that is the build source, else from the '
                'master games database (Settings) when it is downloaded.',
          ),
          _numField(
            _modelGameMinEloCtrl,
            'Model game minimum rating',
            defaultText: '2200',
            onEdited: refresh,
            tooltip:
                'A game between weaker players is not a model game. Games '
                'with no rating at all are still eligible.',
          ),
        ],
      ),
    ];
  }

  /// The master-games database: whether to consult it, and what it may
  /// contribute to the book.
  List<Widget> _exportMasterGameFields(VoidCallback refresh) {
    return [
      const SizedBox(height: 12),
      _labeledCheckbox(
        'Use the master games database',
        _useMasterGames,
        (v) {
          _useMasterGames = v;
          refresh();
        },
        tooltip:
            'When the master games database is downloaded (Settings → Master '
            'games), master practice guides the build: opponent replies come '
            'from titled-player practice blended with Maia, the moves '
            'masters play most are always candidates for your side, lines '
            'that stay in master practice run deeper, model games are real '
            'master games, and a repertoire move that beats what masters '
            'played is annotated "improves on … in <game>". Positions no '
            'master has reached fall back to Maia and the engine. Off: Maia '
            'and the engine alone.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          _numField(
            _masterPriorityWeightCtrl,
            'Master search-order weight',
            defaultText: '0.35',
            onEdited: refresh,
            enabled: _useMasterGames,
            disabledReason: 'Master games are off',
            tooltip:
                'How much a position masters have played jumps the search '
                'queue. The frontier is otherwise ordered on how likely a '
                'line is, which spends the budget on what is probable '
                'rather than on what is known — so under a time limit the '
                'book changed which moves were considered but not which '
                'ones got looked at first. Applied as 1 + weight x ln(1 + '
                'games): two master games already earn a nudge, a 400-game '
                'main line earns roughly triple, and off-book positions are '
                'untouched. 0: pure reach probability, as before.',
          ),
          _numField(
            _masterDepthBonusCtrl,
            'Extra depth in master lines (plies)',
            defaultText: '10',
            onEdited: refresh,
            enabled: _useMasterGames,
            disabledReason: 'Master games are off',
            tooltip:
                'A line may run this many plies past the depth limit while '
                'every position along it is master practice (at least a few '
                'master games). The book is indexed to move 15, so this '
                'never goes past there. 0: all lines stop at the depth '
                'limit.',
          ),
          _numField(
            _offBookOppMaxChildrenCtrl,
            'Opponent replies off-book',
            defaultText: '2',
            onEdited: refresh,
            enabled: _useMasterGames,
            disabledReason: 'Master games are off',
            tooltip:
                'Fan-out cap for opponent replies at positions no master has '
                'reached (Maia-only). Narrower here keeps the tree from '
                'spending its budget on sidelines nobody plays and puts it '
                'into depth where there is practice. Replies likely enough '
                'to need an answer are always kept. 0: same cap as in-book '
                'positions.',
          ),
        ],
      ),
    ];
  }

  /// Punishing a losing reply — showing, as a sideline, why the move the
  /// opponent just played loses.
  List<Widget> _exportRefutationFields(VoidCallback refresh) {
    return [
      const SizedBox(height: 12),
      _labeledCheckbox(
        'Show how a losing reply is punished',
        _refutationLines,
        (v) {
          _refutationLines = v;
          refresh();
        },
        tooltip:
            'When a reply leaves you winning the build stops there, because '
            'there is nothing left to prepare. This asks the engine how the '
            'position is won and writes the answer as a variation on that '
            'move.',
      ),
    ];
  }

  /// Explaining an omission — why a natural-looking move is not the one
  /// the book gives.
  List<Widget> _exportAlternativeFields(VoidCallback refresh) {
    return [
      const SizedBox(height: 12),
      _labeledCheckbox(
        'Show why a natural move is not in the book',
        _alternativeLines,
        (v) {
          _alternativeLines = v;
          refresh();
        },
        tooltip:
            'At each position in a line, the move a human is most likely to '
            'play is checked against the book. When it is missing because it '
            'loses material or the game, the engine\'s answer to it is '
            'written as a variation — the natural move you pass over, and the '
            'try your opponent should avoid. Moves that are simply playable '
            'are left out, so a variation here always means something. Adds '
            'an engine pass after the build.',
      ),
    ];
  }

  List<Widget> _pgnFilterSection(VoidCallback refresh) {
    final isDb = _buildMode == BuildMode.dbExplorer;
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _numField(
            _dbMinGamesCtrl,
            'Min games per move',
            defaultText: '5',
            onEdited: refresh,
            enabled: isDb,
            disabledReason: 'Only used when Build from = My PGN files',
            tooltip:
                'Opponent moves need at least this many games in your PGN '
                'files to be explored.',
          ),
          _numField(
            _dbMinProbCtrl,
            'Min move probability (0–1)',
            defaultText: '0.05',
            onEdited: refresh,
            enabled: isDb,
            disabledReason: 'Only used when Build from = My PGN files',
            tooltip: 'Minimum move frequency to include an opponent reply.',
          ),
          _numField(
            _minEloCtrl,
            'Min player Elo (0 = off)',
            defaultText: '0',
            onEdited: refresh,
            enabled: isDb,
            disabledReason: 'Only used when Build from = My PGN files',
            tooltip: 'Skip games where both players are below this rating.',
          ),
        ],
      ),
    ];
  }
}
