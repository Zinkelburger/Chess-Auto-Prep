part of 'generation_config_form.dart';

/// The advanced gear dialog's *content*: the knobs themselves, grouped into
/// the sections the dialog arranges. Knobs shown on the main form are NOT
/// repeated here.
///
/// All values live in the form state (controllers and fields), so closing
/// the dialog loses nothing and the main form stays in sync.  The
/// eval-sources section is not repeated here either: it is an expander on
/// the main form, one section down.
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
          'Master games',
          Icons.workspace_premium_outlined,
          _masterGamesSection,
        ),
        AdvancedSection(
          'ChessDB book',
          Icons.menu_book_outlined,
          _chessDbBookSection,
          unavailable: () => _buildMode == BuildMode.chessDbBook
              ? null
              : 'These shape the ChessDB mainline book. Set Build from to '
                    'ChessDB mainline book to use them.',
        ),
        AdvancedSection(
          'Verification',
          Icons.verified_outlined,
          _verificationSection,
          unavailable: () => _noVerifyMode
              ? 'This build source takes its moves from a database, so there '
                    'is no search for a deeper pass to second-guess. '
                    'Verification never runs.'
              : null,
        ),
        AdvancedSection(
          'Coverage & line order',
          Icons.playlist_add_check,
          _coverageSection,
        ),
        AdvancedSection(
          'Chapters',
          Icons.auto_stories_outlined,
          _chaptersSection,
        ),
        AdvancedSection(
          'Explanatory variations',
          Icons.alt_route_outlined,
          _variationsSection,
        ),
        AdvancedSection(
          'PGN source filters',
          Icons.filter_alt_outlined,
          _pgnFilterSection,
          unavailable: () => _buildMode == BuildMode.dbExplorer
              ? null
              : 'These filter the games a build reads from your PGN files. '
                    'Set Build from to My PGN files to use them.',
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
                      'prepare. The floor moves with the root, so one setting '
                      'works from any position.\n\n'
                      'Only positions you chose to enter are judged — a '
                      'position the opponent forces on you always gets an '
                      'answer.\n\n'
                      '0 accepts nothing worse than the start, which rules '
                      'out normal opening play and every gambit.'
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
                      'Past this a line stops as already winning. Measured '
                      'from the root, the same way the floor is.'
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
            'On: the two limits above are offsets from the root position\'s '
            'own eval, so the same numbers mean the same thing from any '
            'position. Off: they are absolute centipawn scores, re-picked '
            'per position and per colour.',
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
            _buildMode == BuildMode.dbExplorer ||
            _buildMode == BuildMode.chessDbBook,
      ),
    ];
  }

  List<Widget> _verificationSection(VoidCallback refresh) {
    return [
      _labeledCheckbox(
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
      const SizedBox(height: 8),
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
    ];
  }

  /// How much of the tree reaches the PGN: the coverage target, engine
  /// continuations for lines the ply cap cut off, and line order.
  List<Widget> _coverageSection(VoidCallback refresh) {
    return [
      _numField(
        _lineCoverageCtrl,
        'Coverage target %',
        defaultText: '92',
        onEdited: refresh,
        tooltip:
            'Share of what you will actually face that the export has to '
            'cover. Lines are kept in order of how much new ground each '
            'breaks, and lines that only repeat covered decisions are never '
            'kept. 100% keeps everything that teaches something new.',
      ),
      const SizedBox(height: 8),
      _numField(
        _engineTailCtrl,
        'Engine continuation plies (0 = off)',
        defaultText: '6',
        onEdited: refresh,
        tooltip:
            'Appends this many plies of engine best play, at the verification '
            'depth, to lines the ply cap cut off mid-position. The first '
            'appended move is marked in the PGN as where preparation stopped.',
      ),
      const SizedBox(height: 8),
      _numField(
        _targetLinesCtrl,
        'Hard cap on lines (0 = no cap)',
        defaultText: '0',
        onEdited: refresh,
        tooltip:
            'Stops the export at this many lines even if the coverage target '
            'is not met. Leave at 0 to let coverage decide.',
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
  List<Widget> _chaptersSection(VoidCallback refresh) {
    return [
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
      _labeledCheckbox(
        'One chapter per ECO code',
        _chaptersByEco,
        (v) {
          _chaptersByEco = v;
          refresh();
        },
        enabled: _organizeIntoChapters,
        disabledReason: 'Chapters are off',
        tooltip:
            'Cuts the top level by ECO code instead of by where your '
            'repertoire branches: every line classified B90 lands in the '
            'Najdorf chapter. Oversized codes still split at their branch '
            'points, and sparse ones join the leftovers chapter. Best for a '
            'book spanning many openings.',
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
                'Strong games that follow this repertoire out of the opening, '
                'appended as a final chapter. Taken from your PGN files when '
                'those are the build source, else from the master games '
                'database.',
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
  List<Widget> _masterGamesSection(VoidCallback refresh) {
    return [
      _labeledCheckbox(
        'Use the master games database',
        _useMasterGames,
        (v) {
          _useMasterGames = v;
          refresh();
        },
        tooltip:
            'Guides the build with titled-player practice: opponent replies, '
            'candidate moves for your side, deeper lines where practice '
            'continues, real model games, and "improves on …" notes. Positions '
            'no master has reached fall back to Maia and the engine. Needs the '
            'database (Settings → Master games).',
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
                'How far a position masters have played jumps the search '
                'queue, which is otherwise ordered on how likely a line is. '
                'Applied as 1 + weight × ln(1 + games), so off-book positions '
                'are untouched. 0: order by reach probability alone.',
          ),
          _numField(
            _masterDepthBonusCtrl,
            'Extra depth in master lines (plies)',
            defaultText: '10',
            onEdited: refresh,
            enabled: _useMasterGames,
            disabledReason: 'Master games are off',
            tooltip:
                'Lets a line run this many plies past the depth limit while '
                'every position along it is master practice. The book is '
                'indexed to move 15, so it never goes past there. 0: every '
                'line stops at the depth limit.',
          ),
          _numField(
            _offBookOppMaxChildrenCtrl,
            'Opponent replies off-book',
            defaultText: '2',
            onEdited: refresh,
            enabled: _useMasterGames,
            disabledReason: 'Master games are off',
            tooltip:
                'Cap on opponent replies at positions no master has reached, '
                'so the budget goes into depth where there is practice rather '
                'than sidelines nobody plays. Replies likely enough to need an '
                'answer are always kept. 0: the same cap as in-book positions.',
          ),
        ],
      ),
    ];
  }

  /// The ChessDB mainline book's own knobs.
  ///
  /// These sat in the master-games group, where they were dead weight for
  /// every other build source: three controls greyed out with three
  /// different reasons, none of which had anything to do with master games.
  List<Widget> _chessDbBookSection(VoidCallback refresh) {
    return [
      Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          _numField(
            _bookTailMaxPlyCtrl,
            'Book tail depth (plies)',
            defaultText: '40',
            onEdited: refresh,
            tooltip:
                'How far a ChessDB mainline runs after it leaves master '
                'practice, where there is one database move per side so depth '
                'costs a node per ply instead of a fan-out. Stops earlier if '
                'ChessDB runs out; values below the depth limit are ignored.',
          ),
          _numField(
            _bookTieBreakCtrl,
            'Book tie-break window (cp)',
            defaultText: '0',
            onEdited: refresh,
            tooltip:
                'When ChessDB scores several moves within this many centipawns '
                'of its best, the one masters have played most wins. 0 breaks '
                'exact ties only — common in the opening, and otherwise '
                'settled by the database\'s own ordering.',
          ),
        ],
      ),
      _labeledCheckbox(
        'Let Stockfish finish lines ChessDB cannot',
        _bookEngineFallback,
        (v) {
          _bookEngineFallback = v;
          refresh();
        },
        tooltip:
            'Off, a line ends exactly where ChessDB\'s knowledge ends. On, the '
            'engine searches unknown positions at the engine depth and the '
            'line carries on — far slower, since a database hit costs a '
            'request and an engine search costs seconds. The run summary '
            'reports how many moves came from each.',
      ),
    ];
  }

  /// The two sidelines the export writes to explain a decision rather than
  /// to be memorised: why a losing reply loses, and why a natural-looking
  /// move is not the one the book gives.
  List<Widget> _variationsSection(VoidCallback refresh) => [
    ..._refutationField(refresh),
    ..._alternativeField(refresh),
  ];

  List<Widget> _refutationField(VoidCallback refresh) {
    return [
      _labeledCheckbox(
        'Show how a losing reply is punished',
        _refutationLines,
        (v) {
          _refutationLines = v;
          refresh();
        },
        tooltip:
            'When a reply leaves you winning the build stops there. This asks '
            'the engine how the position is won and writes the answer as a '
            'variation on that move.',
      ),
    ];
  }

  List<Widget> _alternativeField(VoidCallback refresh) {
    return [
      const SizedBox(height: 8),
      _labeledCheckbox(
        'Show why a natural move is not in the book',
        _alternativeLines,
        (v) {
          _alternativeLines = v;
          refresh();
        },
        tooltip:
            'Checks the move a human is most likely to play at each position; '
            'when it is missing because it loses material or the game, writes '
            'the engine\'s refutation as a variation. Moves that are simply '
            'playable are left out. Adds an engine pass after the build.',
      ),
    ];
  }

  List<Widget> _pgnFilterSection(VoidCallback refresh) {
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
