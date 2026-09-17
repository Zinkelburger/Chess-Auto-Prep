import '../models/pgn_document.dart';
import '../models/viewer_collection_load.dart';
import '../repositories/pgn_collection_decoder.dart';
import '../repositories/pgn_collection_repository.dart';

/// Owns collection request lifetime. Superseded work may finish in its adapter,
/// but can never return a publishable document or failure to the host.
class ViewerCollectionLoadController {
  ViewerCollectionLoadController({
    required this.repository,
    required this.decoder,
  });
  final PgnCollectionRepository repository;
  final PgnCollectionDecoder decoder;
  int _revision = 0;
  bool _disposed = false;
  int get revision => _revision;
  bool isCurrent(int request) => !_disposed && request == _revision;

  int invalidate() => ++_revision;

  Future<ViewerCollectionLoadResult?> loadFile(String path) async {
    if (_disposed) return null;
    final request = invalidate();
    try {
      final opened = await repository.open(path);
      if (!isCurrent(request)) return null;
      switch (opened) {
        case PgnMissing():
          return const ViewerCollectionLoadFailed(
            ViewerCollectionLoadFailure.missing,
          );
        case PgnReadFailed(:final error):
          return ViewerCollectionLoadFailed(
            ViewerCollectionLoadFailure.unreadable,
            error,
          );
        case PgnOpened(:final snapshot):
          final decoded = await _decode(snapshot.content, request);
          if (!isCurrent(request)) return null;
          if (decoded is! ViewerCollectionLoaded) return decoded;
          final modified = await repository.modified(path);
          if (!isCurrent(request)) return null;
          return ViewerCollectionLoaded(
            decoded.document,
            snapshot: snapshot,
            modified: modified,
          );
      }
    } catch (error) {
      if (!isCurrent(request)) return null;
      return ViewerCollectionLoadFailed(
        ViewerCollectionLoadFailure.unreadable,
        error,
      );
    }
  }

  Future<ViewerCollectionLoadResult?> loadText(String content) {
    if (_disposed) return Future.value(null);
    return _decode(content, invalidate());
  }

  Future<ViewerCollectionLoadResult?> _decode(
    String content,
    int request,
  ) async {
    if (content.trim().isEmpty) {
      return const ViewerCollectionLoadFailed(
        ViewerCollectionLoadFailure.empty,
      );
    }
    try {
      final document = await decoder.decode(content);
      if (!isCurrent(request)) return null;
      if (document.games.isEmpty) {
        return const ViewerCollectionLoadFailed(
          ViewerCollectionLoadFailure.noGames,
        );
      }
      return ViewerCollectionLoaded(document);
    } catch (error) {
      if (!isCurrent(request)) return null;
      return ViewerCollectionLoadFailed(
        ViewerCollectionLoadFailure.decoding,
        error,
      );
    }
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }
}
