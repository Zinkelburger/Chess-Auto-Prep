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
        if (_buildMode != BuildMode.stockfishExpectimax)
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
          'Line order & tails',
          Icons.playlist_add_check,
          _coverageSection,
        ),
        AdvancedSection(
          'Chapters',
          Icons.auto_stories_outlined,
          _chaptersSection,
        ),
        AdvancedSection(
          'Extra variations',
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

  List<Widget> _opponentModelSection(VoidCallback refresh) => [
    _caption(
      'Pure and Fast use Maia at the selected rating for every opponent position, '
      'normalized over legal moves. No database frequencies or hidden mixture.',
    ),
  ];

  List<Widget> _moveChoiceSection(VoidCallback refresh) => [
    _caption(
      'Choose the highest expected-score estimate among all legal moves '
      'within the engine-loss limit. No novelty, memorability, setup or reply-count bonuses.',
    ),
    _numField(
      _evalGuardCtrl,
      'Maximum engine loss (cp)',
      defaultText: '30',
      onEdited: refresh,
      tooltip:
          'Compared with the best of all legal moves evaluated at the same engine depth.',
    ),
  ];

  List<Widget> _searchBudgetSection(VoidCallback refresh) => [
    _caption(
      'Pure enumerates the complete action set at each expanded position. '
      'Time and node limits produce an explicitly incomplete result; they do not prune rare replies.',
    ),
    EngineResourcesSection(
      threadsController: _engineThreadsCtrl,
      isGenerating: widget.isGenerating,
      isDbExplorer: _buildMode == BuildMode.dbExplorer,
      enabled: _usesEngineDepth,
    ),
  ];

  List<Widget> _verificationSection(VoidCallback refresh) => [
    _caption(
      'Pure evaluates every legal candidate at the engine depth on the main form. '
      'There is no separate mixed-depth verification pass and no claim of an objective chess proof.',
    ),
  ];

  List<Widget> _coverageSection(VoidCallback refresh) {
    return [
      if (_buildMode != BuildMode.stockfishExpectimax)
        _numField(
          _engineTailCtrl,
          'Engine continuation plies',
          defaultText: '6',
          onEdited: refresh,
          tooltip:
              'Appends this many plies of engine best play, at the verification '
              'depth, to lines the ply cap cut off mid-position. The first '
              'appended move is marked in the PGN as where preparation stopped.',
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
      ChoiceField<MoveAnnotationDetail>(
        label: 'Per-move annotations',
        value: _annotationDetail,
        enabled: !widget.isGenerating,
        items: const [
          ChoiceItem(
            value: MoveAnnotationDetail.none,
            label: 'None — moves only',
          ),
          ChoiceItem(
            value: MoveAnnotationDetail.likelihood,
            label: 'Reply likelihood',
          ),
          ChoiceItem(
            value: MoveAnnotationDetail.full,
            label: 'Full — eval, ease, scores',
          ),
        ],
        onChanged: (v) {
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
  List<Widget> _masterGamesSection(VoidCallback refresh) => [
    _caption(
      'Select Target master opponents on the main form to use master-game '
      'reply frequencies. Untick it for Maia at your chosen rating throughout. '
      'Master games do not change the search horizon or receive extra search priority.',
    ),
  ];

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
