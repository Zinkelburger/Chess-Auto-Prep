import 'package:collection/collection.dart';

import '../storage/pgn_document_store.dart' as store;

/// The saves of one document that can still be taken back.
///
/// A receipt is the store's own record of a write: the version it replaced
/// and the version it committed. Stepping back is writing that earlier
/// version again, so this keeps no text of its own and decides only which
/// receipt is next and what the rest of them mean afterwards.
final class UndoHistory {
  /// Undo is for the mistake you just made, not a version history; the
  /// versions themselves are kept in Support by the store.
  static const depth = 20;

  final _entries = <store.Receipt>[];

  bool get isEmpty => _entries.isEmpty;

  /// The save the next undo takes back, or null when there is none.
  store.Receipt? get newest => _entries.lastOrNull;

  /// The history of the document that was open. A new document takes none of
  /// it: the file those receipts name is not the one being written now.
  void clear() => _entries.clear();

  void keep(store.Receipt receipt) {
    _entries.add(receipt);
    if (_entries.length > depth) _entries.removeAt(0);
  }

  /// [undone] has been taken back by writing [written].
  ///
  /// The entry below it holds content that is on disk again, but as the file
  /// the undo wrote, so it is pointed at that revision. An entry whose
  /// revision was not the one the undone save replaced is left alone:
  /// something else wrote in between, and undoing to it would throw that
  /// away.
  void tookBack(store.Receipt undone, store.Receipt written) {
    _entries.removeLast();
    final previous = _entries.lastOrNull;
    if (previous == null || previous.committed != undone.beforeRevision) {
      return;
    }
    _entries[_entries.length - 1] = store.Receipt(
      committed: written.committed,
      before: previous.before,
      beforeRevision: previous.beforeRevision,
    );
  }
}
