part of 'analysis_screen.dart';

/// Keep the player's personal study available to the existing board actions.
/// Player records and reference links are edited in the player database.
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
        : () => _opponentActions.prepFiles.preferredFor(prep.person, null);
    // The chapter is named for the colour *I* hold against them.
    _boardActions.chapterPrefix = prep == null
        ? null
        : () =>
              '${prep.person.name} · ${_playerIsWhite ? 'As Black' : 'As White'}';
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
