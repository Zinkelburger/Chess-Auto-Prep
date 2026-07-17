/// What the user chose on the games source form.
///
/// Lives in the service layer (not the form widget) so that
/// [GamesDraftController] can depend on it without importing widgets.
library;

import '../games_library/game_filter.dart';
import '../games_library/games_library_service.dart';

class GamesSourceConfig {
  const GamesSourceConfig({
    required this.platform,
    required this.username,
    required this.isWhite,
    required this.selection,
    this.startMoves = const [],
  });

  final GamesPlatform platform;
  final String username;
  final bool isWhite;
  final GameSelection selection;

  /// When non-empty, only draft from games that follow these SAN moves from
  /// the game start (the board position when the form was opened).
  final List<String> startMoves;
}
