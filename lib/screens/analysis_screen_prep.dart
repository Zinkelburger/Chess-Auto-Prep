part of 'analysis_screen.dart';

/// Player Analysis when the player is someone in the opponents directory:
/// their prep file is one menu entry away, "Add line to study…" offers it
/// first, and — opened from a tournament sheet — the field is a list to walk:
/// tick them off, move to the next one, or go back to the sheet.
///
/// "Check against my repertoire…" lives here too but works for any player:
/// it needs only the tree on screen and the book designated for the other
/// colour.
mixin _PrepMixin on _AnalysisScreenStateBase {
  void _onOpponentsChanged() {
    if (!mounted) return;
    setState(_resolvePrep);
  }

  /// Re-read who the current player is in the directory (and where in the
  /// field), then point the board's study handoff at their prep file.
  void _resolvePrep() {
    final player = _currentPlayer;
    _prep = player == null ? null : PrepContext.resolve(_opponents, player);
    final prep = _prep;
    _boardActions.preferredStudy = prep == null
        ? null
        : () => _opponentActions.prepFiles.ensure(prep.person);
    // The chapter is named for the colour *I* hold against them.
    _boardActions.chapterPrefix = prep == null
        ? null
        : () => _playerIsWhite ? 'As Black' : 'As White';
  }

  /// ` · Spring Open 2026 · 3 of 12` for the app-bar subtitle, or ''.
  String get _prepSubtitle {
    final prep = _prep;
    return prep == null || !prep.inTournament ? '' : ' · ${prep.label}';
  }

  List<AppMenuEntry> _prepMenuEntries() {
    final prep = _prep;
    if (prep == null) return const [];
    final next = prep.neighbour(_opponents, 1);
    final prev = prep.neighbour(_opponents, -1);
    final entry = prep.entry;
    return [
      AppMenuEntry(
        label: 'Open prep file: ${prep.person.name}',
        dividerAbove: true,
        onRun: () =>
            unawaited(_opponentActions.openPrepFile(context, prep.person)),
        hint:
            'The study holding your notes and lines against '
            '${prep.person.name}. "Add line to study…" offers it first.',
      ),
      if (entry != null) ...[
        AppMenuEntry(
          label: 'Prepared',
          checked: entry.prepared,
          onRun: () => unawaited(_togglePrepared()),
          hint: 'Tick when your prep for them is done; the sheet shows it.',
        ),
        AppMenuEntry(
          label: next == null ? 'Next opponent' : 'Next: ${next.name}',
          enabled: next != null,
          onRun: () => unawaited(_switchToPerson(next!)),
        ),
        AppMenuEntry(
          label: prev == null ? 'Previous opponent' : 'Previous: ${prev.name}',
          enabled: prev != null,
          onRun: () => unawaited(_switchToPerson(prev!)),
        ),
        AppMenuEntry(
          label: 'Tournament sheet…',
          onRun: () => unawaited(_openTournamentSheet()),
        ),
      ],
    ];
  }

  Future<void> _togglePrepared() async {
    final prep = _prep;
    final entry = prep?.entry;
    final tournament = prep?.tournament;
    if (entry == null || tournament == null) return;
    await _opponents.saveTournament(
      tournament.withEntry(entry.copyWith(prepared: !entry.prepared)),
    );
  }

  /// Load another person's games, downloading them first if they are not
  /// on disk yet.
  Future<void> _switchToPerson(PersonRecord person) async {
    final group = _prep?.tournament?.name;
    final info = await _opponentActions.ensureGames(
      context,
      person,
      group: group,
    );
    if (info == null || !mounted) return;
    await _selectPlayer(info);
  }

  Future<void> _openTournamentSheet() async {
    final tournament = _prep?.tournament;
    if (tournament == null) return;
    final picked = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(
        builder: (_) => TournamentScreen(
          tournamentId: tournament.id,
          store: _opponents,
          actions: _opponentActions,
        ),
      ),
    );
    if (picked != null && mounted) await _selectPlayer(picked);
  }

  Future<void> _runRepertoireCheck() async {
    final tree = _openingTree;
    final player = _currentPlayer;
    if (tree == null || player == null) return;
    final opponentIsWhite = _playerIsWhite;
    final report = await RepertoireCheck().run(
      tree: tree,
      opponentIsWhite: opponentIsWhite,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => RepertoireCheckDialog(
        report: report,
        opponentName: player.displayName,
        opponentIsWhite: opponentIsWhite,
        onGoTo: _goToFen,
      ),
    );
  }

  void _goToFen(String fen) {
    if (!mounted) return;
    setState(() {
      _navigateFen = fen;
      _navigateGeneration++;
    });
  }
}
