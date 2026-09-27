import '../models/viewer_session.dart';
import '../repositories/viewer_preferences_repository.dart';

/// Owns ordered reading-position checkpoints. A failed checkpoint remains
/// retryable; only an acknowledged write suppresses a duplicate. Errors are
/// observable without leaking unhandled futures from navigation or disposal.
class ViewerSessionController {
  ViewerSessionController(this.repository);
  final ViewerPreferencesRepository repository;
  Future<void> _tail = Future.value();
  String? _saved;
  Object? _error;
  Object? get error => _error;

  Future<bool> save(String path, ViewerSession session) {
    final identity = '$path:${session.encode()}';
    return _enqueue(() async {
      if (_saved == identity && _error == null) return;
      await repository.saveSession(path, session);
      _saved = identity;
    });
  }

  Future<bool> close() => _enqueue(() async {
    await repository.closeSession();
    _saved = null;
  });

  Future<ViewerSession?> load(String path) async {
    await _tail;
    return repository.loadSession(path);
  }

  Future<String?> lastFile() async {
    await _tail;
    return repository.lastFile();
  }

  Future<bool> flush() async {
    await _tail;
    return _error == null;
  }

  Future<bool> _enqueue(Future<void> Function() action) {
    final completed = _tail.then((_) async {
      try {
        await action();
        _error = null;
        return true;
      } catch (error) {
        _error = error;
        return false;
      }
    });
    _tail = completed.then((_) {});
    return completed;
  }
}
