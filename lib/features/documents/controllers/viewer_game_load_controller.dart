import '../../../chess_core/pgn/pgn_parser.dart';
import '../repositories/stored_game_repository.dart';
import '../models/viewer_game_load_state.dart';
import 'viewer_game_controller.dart';

/// Owns asynchronous game replacement. Every request revokes older reads and
/// deferred host callbacks, including when a new request fails or is empty.
/// An archive read may finish after disposal; it can no longer publish a game.
class ViewerGameLoadController {
  ViewerGameLoadController({required this.game, this.storedGames});

  final ViewerGameController game;
  final StoredGameRepository? storedGames;
  Object _revision = Object();
  bool _disposed = false;
  ViewerGameLoadState _state = const ViewerGameLoadIdle();

  Object get revision => _revision;
  ViewerGameLoadState get state => _state;
  bool get isLoading => _state is ViewerGameLoading;
  ViewerGameLoadFailure? get failure => switch (_state) {
    ViewerGameLoadFailed(:final failure) => failure,
    _ => null,
  };
  bool isCurrent(Object revision) =>
      !_disposed && identical(revision, _revision);

  Future<bool> load({String? gameId, String? pgnText}) async {
    if (_disposed) return false;
    final request = _revision = Object();
    _state = const ViewerGameLoading();
    var text = '';
    var archiveFailed = false;
    if (gameId != null && gameId.isNotEmpty) {
      try {
        final repository = storedGames;
        if (repository == null) {
          archiveFailed = true;
        } else {
          text = await repository.findById(gameId) ?? '';
        }
      } catch (_) {
        archiveFailed = true;
      }
      if (!isCurrent(request)) return false;
    }
    if (text.trim().isEmpty) text = pgnText ?? '';
    if (text.trim().isEmpty) {
      _state = ViewerGameLoadFailed(
        archiveFailed
            ? ViewerGameLoadFailure.archiveUnavailable
            : gameId != null && gameId.isNotEmpty
            ? ViewerGameLoadFailure.notFound
            : ViewerGameLoadFailure.noInput,
      );
      return false;
    }
    try {
      game.load(parsePgnGame(text));
    } catch (_) {
      _state = const ViewerGameLoadFailed(ViewerGameLoadFailure.invalidPgn);
      return false;
    }
    _state = const ViewerGameLoaded();
    return true;
  }

  void dispose() {
    _disposed = true;
    _revision = Object();
    _state = const ViewerGameLoadClosed();
  }
}
