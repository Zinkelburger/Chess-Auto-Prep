import 'package:collection/collection.dart';

import '../../storage/document_ref.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart' as store;

/// A save that can be taken back: the store's receipt for it, and the scope
/// it was written under — which games of the version the receipt says it
/// replaced the save changed. Kept in memory with the receipt, for as long
/// as the receipt is.
typedef KeptSave = ({store.Receipt receipt, EditScope scope});

/// The saves of a document that can still be taken back, set aside while
/// another document is up: the file they were written to, the revision the
/// last write left it at, and the saves, oldest first. They are good only
/// for that file at that revision; anything else wrote it since.
typedef SetAsideUndo = ({String path, Revision revision, List<KeptSave> saves});

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

  final _entries = <KeptSave>[];

  bool get isEmpty => _entries.isEmpty;

  /// The save the next undo takes back, or null when there is none.
  KeptSave? get newest => _entries.lastOrNull;

  /// The history of the document that was open. A new document takes none of
  /// it: the file those receipts name is not the one being written now.
  void clear() => _entries.clear();

  /// Every entry, oldest first, leaving this history empty.
  List<KeptSave> takeAll() {
    final all = List.of(_entries);
    _entries.clear();
    return all;
  }

  /// [saves], taken out with [takeAll], in place of what this held.
  void putBack(List<KeptSave> saves) => _entries
    ..clear()
    ..addAll(saves);

  /// [receipt] is the store's answer to a save made under [scope].
  void keep(store.Receipt receipt, EditScope scope) {
    _entries.add((receipt: receipt, scope: scope));
    if (_entries.length > depth) _entries.removeAt(0);
  }

  /// [undone] has been taken back by writing [written].
  ///
  /// The entry below it holds content that is on disk again, but as the file
  /// the undo wrote, so it is pointed at that revision; what that save
  /// changed is what it always was. An entry whose revision was not the one
  /// the undone save replaced is left alone: something else wrote in
  /// between, and undoing to it would throw that away.
  void tookBack(store.Receipt undone, store.Receipt written) {
    _entries.removeLast();
    final previous = _entries.lastOrNull;
    if (previous == null ||
        previous.receipt.committed != undone.beforeRevision) {
      return;
    }
    _entries[_entries.length - 1] = (
      receipt: store.Receipt(
        committed: written.committed,
        before: previous.receipt.before,
        beforeRevision: previous.receipt.beforeRevision,
        compound: previous.receipt.compound,
        secondaryRef: previous.receipt.secondaryRef,
      ),
      scope: previous.scope,
    );
  }
}
