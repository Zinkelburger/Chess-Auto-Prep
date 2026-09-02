part of 'generation_config_form.dart';

mixin _GenerationConfigDescriptions on _GenerationConfigFormStateBase {
  String selectionModeDescription() => _selectionModeDescription();

  String _buildModeDescription() {
    switch (_buildMode) {
      case BuildMode.stockfishExpectimax:
        return 'Stockfish evaluates every position; Maia predicts opponent '
            'moves. Thorough but slower.';
      case BuildMode.maiaDbExplore:
        return 'Maia moves and database win rates only — fast, no engine '
            'needed. Requires an evaluation database, enabled below.';
      case BuildMode.dbExplorer:
        return 'Builds from the PGN files listed below. Move frequencies '
            'come from those games; engine evals are added afterwards.';
      case BuildMode.chessDbBook:
        return 'Plays whatever ChessDB ranks best: one move per position, no '
            'engine search, no human model. Branches only where masters have '
            'branched, then runs on as a single mainline. Needs the ChessDB '
            'dump or API, enabled below.';
    }
  }

  String _selectionModeLabel(SelectionMode mode) => switch (mode) {
    SelectionMode.expectimax => 'Best expected score (recommended)',
    SelectionMode.engineOnly => 'Engine best move',
    SelectionMode.dbWinRateOnly => 'Database win rate',
  };

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
    }
  }
}
