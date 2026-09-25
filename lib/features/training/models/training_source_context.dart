import '../../documents/models/pgn_document.dart';

/// Authority held by one loaded training source, including its queued writes.
/// A fresh read never renews it. Only this source's acknowledged header save
/// advances its revision; replacement or relocation requires a new load.
final class TrainingSourceContext {
  TrainingSourceContext({required this.path, required this._snapshot});

  final String path;
  PgnSnapshot _snapshot;
  PgnSnapshot get snapshot => _snapshot;

  Future<void> _operations = Future<void>.value();

  /// Serialize use of this source with acknowledgement of its own header save.
  /// Acquire this turn before entering storage's recovery domain, never within
  /// it: a queued header operation may still need that domain to publish.
  Future<T> run<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void acknowledge(PgnSaved saved) {
    if (saved.before?.revision != _snapshot.revision ||
        saved.after.path != _snapshot.path) {
      throw StateError('The header save belongs to another training source.');
    }
    _snapshot = saved.after;
  }
}

/// A definitive source rejection before this persistence stage writes anything.
/// Earlier stages or earlier failures may still have published participants.
final class TrainingSourceChanged extends StateError {
  TrainingSourceChanged()
    : super(
        'The training source moved or changed. Restore the original source before retrying.',
      );
}
