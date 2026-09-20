import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import '../storage/document_ref.dart';
import '../storage/pgn_document_store.dart' as store;

/// What the file on disk is doing. Only [Saved] says it holds what the
/// screen shows.
sealed class SaveState {
  const SaveState();
}

final class Saved extends SaveState {
  const Saved();
}

final class Saving extends SaveState {
  const Saving();
}

/// Edited and not written yet, either waiting for a save in flight or on its
/// way out this instant.
final class Unsaved extends SaveState {
  const Unsaved();
}

final class SaveFailed extends SaveState {
  const SaveFailed(this.detail);

  /// The operating system's words; the widget writes the sentence.
  final String detail;
}

/// Someone else wrote the file. The draft is kept and nothing more is
/// written until the user chooses what to do with it.
final class SaveConflict extends SaveState {
  const SaveConflict();
}

sealed class UndoResult {
  const UndoResult();
}

/// The file is back at [text]; the caller reads its document from it again.
final class Restored extends UndoResult {
  const Restored(this.text);

  final String text;
}

/// Nothing was undone, and the history is as it was.
final class UndoRefused extends UndoResult {
  const UndoRefused();
}

typedef _Target = ({DocumentRef ref, Revision revision});

/// Keeps one document's file matching the draft the user is editing.
///
/// Saves are immediate: an edit asks for one and it goes out. Only one is in
/// flight at a time and edits made during it collapse into a single pending
/// save of the newest text, so a burst of moves cannot become a queue of
/// stale snapshots. Undo is the store's own receipts played backwards; this
/// owner never remembers a version itself.
final class DocumentSaver extends ChangeNotifier {
  DocumentSaver(this._store);

  /// Undo is for the mistake you just made, not a version history; the
  /// versions themselves are kept in Support by the store.
  static const undoDepth = 20;

  final store.PgnDocumentStore _store;
  _Target? _target;
  SaveState _state = const Saved();
  String? _pending;
  bool _writing = false;

  /// The write going out and everything that collapses behind it, so the
  /// app can wait for the file to hold the draft before it closes.
  Future<void>? _inFlight;
  final _undo = <store.Receipt>[];
  int _opens = 0;
  bool _disposed = false;

  SaveState get state => _state;

  bool get canUndo => _undo.isNotEmpty;

  /// A document was opened. It is what the saver writes from now on, and
  /// nothing of the last one — its draft, its receipts — is carried over.
  void opened(DocumentRef ref, Revision revision) {
    _opens++;
    _target = (ref: ref, revision: revision);
    _pending = null;
    _undo.clear();
    _set(const Saved());
  }

  /// Puts [text] on disk. While the file is conflicted nothing is written:
  /// the user reloads, saves a copy, or keeps editing a draft that is theirs
  /// to keep.
  void save(String text) {
    if (_state is SaveConflict) return;
    _pending = text;
    _set(const Unsaved());
    if (!_writing) _inFlight = _write();
  }

  /// Waits until the draft is on disk: the write in flight and the one that
  /// collapsed behind it. Closing the window waits for this, so an edit made
  /// a moment before it closed is not cut off.
  Future<void> flush() => _inFlight ?? Future<void>.value();

  Future<void> _write() async {
    final target = _target;
    final text = _pending;
    if (_writing || target == null || text == null) return;
    _pending = null;
    _writing = true;
    _set(const Saving());
    final ticket = _opens;
    final result = await _store.save(
      target.ref,
      text,
      expected: target.revision,
    );
    _writing = false;
    if (_disposed) return;
    if (ticket != _opens) {
      // The answer is about an open nobody is on any more; a newer one may
      // have been waiting behind it.
      _catchUp(result, target.ref);
      await _write();
      return;
    }
    _adopt(result, target.ref);
    if (_state is! SaveConflict) await _write();
  }

  /// A write that landed after its document was opened again. When it wrote
  /// the file that is open now, the revision it committed is the newest
  /// there is and the next save must expect it; without that the document
  /// would conflict with this app's own write. Its receipt belongs to the
  /// open that asked for it, so it is not history here.
  void _catchUp(store.SaveResult result, DocumentRef ref) {
    final target = _target;
    if (target == null || target.ref != ref) return;
    if (result case store.Saved(:final receipt)) {
      _target = (ref: ref, revision: receipt.committed);
    }
  }

  void _adopt(store.SaveResult result, DocumentRef ref) {
    switch (result) {
      case store.Saved(:final receipt):
        _target = (ref: ref, revision: receipt.committed);
        _keep(receipt);
        _set(const Saved());
      case store.Conflict():
        // The store logs what it could not do; a conflict is not a failure
        // there, so it is named here.
        log.w('save ${ref.path}', 'the file changed on disk');
        _conflicted();
      case store.IoFailure(:final detail):
        _set(SaveFailed(detail));
    }
  }

  void _keep(store.Receipt receipt) {
    _undo.add(receipt);
    if (_undo.length > undoDepth) _undo.removeAt(0);
  }

  /// Puts the version before the last save back, through the store, so the
  /// undo is itself a save: it is refused if the file changed underneath and
  /// it is recorded like any other write.
  ///
  /// Waits for a draft on its way out: there is nothing to undo to while the
  /// newest text is still going to disk.
  Future<UndoResult> undo() async {
    final target = _target;
    if (target == null || _undo.isEmpty || _writing || _pending != null) {
      return const UndoRefused();
    }
    final entry = _undo.last;
    final resting = _state;
    _writing = true;
    _set(const Saving());
    final ticket = _opens;
    final result = await _store.save(
      target.ref,
      entry.before,
      expected: entry.committed,
    );
    _writing = false;
    if (_disposed || ticket != _opens) return const UndoRefused();
    if (_outOfDate(result, target)) {
      _set(resting);
      return const UndoRefused();
    }
    return _undone(result, entry, target.ref);
  }

  /// Whether the store refused because the entry names a revision the
  /// document has left behind rather than because the file changed: what is
  /// on disk is the revision this saver already holds.
  ///
  /// Only this entry is out of reach. The draft is still the file's, so the
  /// document is not conflicted and saving goes on.
  bool _outOfDate(store.SaveResult result, _Target target) =>
      result is store.Conflict && result.current == target.revision;

  UndoResult _undone(
    store.SaveResult result,
    store.Receipt entry,
    DocumentRef ref,
  ) {
    switch (result) {
      case store.Saved(:final receipt):
        _undo.removeLast();
        _rearm(entry, receipt);
        _target = (ref: ref, revision: receipt.committed);
        _set(const Saved());
        return Restored(entry.before);
      case store.Conflict():
        log.w('undo ${ref.path}', 'the file changed on disk');
        _conflicted();
        return const UndoRefused();
      case store.IoFailure(:final detail):
        _set(SaveFailed(detail));
        return const UndoRefused();
    }
  }

  /// The entry below the one just undone holds content that is on disk
  /// again, but as the file the undo wrote, so it is pointed at that
  /// revision. An entry whose revision was not the one the undone save
  /// replaced is left alone: something else wrote in between, and undoing to
  /// it would throw that away.
  void _rearm(store.Receipt undone, store.Receipt written) {
    if (_undo.isEmpty) return;
    final previous = _undo.last;
    if (previous.committed != undone.beforeRevision) return;
    _undo[_undo.length - 1] = store.Receipt(
      committed: written.committed,
      before: previous.before,
      beforeRevision: previous.beforeRevision,
    );
  }

  /// Nothing is written while the file is conflicted, so a draft that was
  /// waiting its turn is waiting for nothing. Remembering it would refuse
  /// every undo for the life of the document.
  void _conflicted() {
    _pending = null;
    _set(const SaveConflict());
  }

  void _set(SaveState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
