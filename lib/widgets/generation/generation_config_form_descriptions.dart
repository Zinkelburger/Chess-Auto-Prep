part of 'generation_config_form.dart';

mixin _GenerationConfigDescriptions on _GenerationConfigFormStateBase {
  String selectionModeDescription() => _selectionModeDescription();

  String _buildModeLabel(BuildMode mode) {
    switch (mode) {
      case BuildMode.stockfishExpectimax:
        return 'Stockfish Expectimax';
      case BuildMode.maiaDbExplore:
        return 'DB Win Rate Only';
      case BuildMode.dbExplorer:
        return 'From Added PGN Files';
      case BuildMode.trapFinder:
        return 'Trap Finder';
    }
  }

  String _buildModeDescription() {
    switch (_buildMode) {
      case BuildMode.stockfishExpectimax:
        return 'Stockfish evaluates every position; Maia predicts opponent '
            'moves. Thorough but slower.';
      case BuildMode.maiaDbExplore:
        return 'Uses Maia neural-net moves + database win rates only — '
            'fast, no engine needed.';
      case BuildMode.dbExplorer:
        return 'Builds from PGN files you add below—not from lines already '
            'in your repertoire. Uses move frequencies from those games; '
            'engine evals added after.';
      case BuildMode.trapFinder:
        return 'Not yet available.';
    }
  }

  String _selectionModeDescription() {
    switch (_selectionMode) {
      case SelectionMode.expectimax:
        return 'Picks lines by weighing engine eval against how opponents '
            'actually play. Best overall results.';
      case SelectionMode.engineOnly:
        return 'Always picks the engine\'s top move. Strong but may choose '
            'lines that are hard to remember.';
      case SelectionMode.dbWinRateOnly:
        return 'Picks moves by practical win rate from game databases. '
            'Falls back to engine eval when no data is available.';
      case SelectionMode.playable:
        return 'Balances strength (60%) with ease of play (40%) — prefers '
            'moves that are both sound and natural to find over the board.';
      case SelectionMode.trappy:
        return 'Picks lines where opponents are most likely to blunder. '
            'Uses expected centipawn loss instead of win probability. '
            'Build tolerances are automatically widened to explore '
            'trickier positions.';
    }
  }
}
