import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import '../storage/document_ref.dart';
import '../storage/pgn_document_store.dart' as store;
import 'undo_history.dart';

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

  final store.PgnDocumentStore _store;
  _Target? _target;
  SaveState _state = const Saved();
  String? _pending;
  bool _writing = false;

  /// The write going out and everything that collapses behind it, so the
  /// app can wait for the file to hold the draft before it closes.
  Future<void>? _inFlight;
  final _undo = UndoHistory();
  int _opens = 0;
  bool _disposed = false;

  /// The file is being renamed, moved or deleted, so nothing is written to it
  /// until that is done.
  bool _held = false;

  SaveState get state => _state;

  bool get canUndo => !_undo.isEmpty;

  /// Whether the file holds the words the user has typed.
  ///
  /// False while a write is going out and while a draft waits behind one,
  /// and false for as long as a save has been refused or has failed: those
  /// leave words on the screen that are in no file. Closing the window asks
  /// this, because [flush] only says that nothing is on its way, not that
  /// anything arrived.
  bool get settled => _state is Saved && _pending == null;

  /// The file being written, for a log line or a sentence about it.
  String? get documentPath => _target?.ref.path;

  /// A document was opened. It is what the saver writes from now on, and
  /// nothing of the last one — its draft, its receipts — is carried over.
  ///
  /// The draft of the document being replaced must already be on disk, which
  /// is why the caller waits for [flush] first: a draft waiting behind a hold
  /// belongs to the file it was typed into, and this cannot write it there
  /// once the target has changed.
  void opened(DocumentRef ref, Revision revision) {
    _opens++;
    _target = (ref: ref, revision: revision);
    _pending = null;
    _undo.clear();
    _set(const Saved());
  }

  /// Puts [text] on disk. While the file is conflicted nothing is written:
  /// the user reloads, saves a copy, or keeps editing a draft that is theirs
  /// to keep. The text is not remembered then — keeping it would refuse
  /// every undo for the life of the document — but the conflict itself says
  /// the document is not [settled], so nothing takes the file for the
  /// document.
  void save(String text) {
    if (_state is SaveConflict) return;
    _pending = text;
    _set(const Unsaved());
    _start();
  }

  /// Waits until nothing is on its way any more: the write in flight, the
  /// one that collapsed behind it, and a hold that is keeping both waiting.
  /// Closing the window waits for this, so an edit made a moment before it
  /// closed is not cut off. Whether the words arrived is [settled]; a write
  /// that was refused or failed also ends the wait.
  Future<void> flush() => _inFlight ?? Future<void>.value();

  /// Runs [action] against the revision the file has now, with the file held
  /// still: the write on its way out finishes first, and a save asked for
  /// while [action] runs waits behind it and goes to wherever the document
  /// ends up. Answers null when there is nothing open or another hold is
  /// running.
  ///
  /// This is how a rename, move or delete of the open chapter is serialised
  /// with autosave. The alternative — letting the save go and renaming
  /// afterwards — would leave the rename racing an answer it cannot see, and
  /// a lost race means the user is told their file changed on disk when the
  /// only thing that wrote it was this app.
  Future<T?> holdStill<T>(Future<T> Function(Revision revision) action) {
    if (_held || _disposed) return Future<T?>.value();
    final held = _hold(action);
    // The hold and the draft waiting behind it are now what the draft is
    // waiting on, so a flush waits for the whole of it rather than for a
    // write that finished before the hold began. What is kept here can only
    // complete, never fail: an action that throws is the caller's to handle,
    // and a failed future left here would throw again at every later flush
    // and at the end of every later hold.
    _inFlight = held.then<void>((_) {}, onError: (Object _) {});
    return held;
  }

  Future<T?> _hold<T>(Future<T> Function(Revision revision) action) async {
    _held = true;
    try {
      await flush();
      final target = _target;
      if (_disposed || target == null) return null;
      return await action(target.revision);
    } finally {
      _held = false;
      await _write();
    }
  }

  /// The open document is now at [ref]: the same file with the same bytes
  /// under another name, so the revision and the undo receipts still stand.
  void relocated(DocumentRef ref) {
    final target = _target;
    if (target == null) return;
    _target = (ref: ref, revision: target.revision);
  }

  /// The open document is gone. Nothing more is written to it, and its undo
  /// history goes with it: the file those receipts name is not there to
  /// restore into.
  void closed() {
    _opens++;
    _target = null;
    _pending = null;
    _undo.clear();
    _set(const Saved());
  }

  /// Puts the draft on its way, unless a write is already going — it takes
  /// the newest text when it lands — or the file is held still.
  void _start() {
    if (_held || _writing || _disposed) return;
    _inFlight = _write();
  }

  Future<void> _write() async {
    final target = _target;
    final text = _pending;
    if (_held || _writing || target == null || text == null) return;
    _pending = null;
    _writing = true;
    _set(const Saving());
    final ticket = _opens;
    final result = await _put(target.ref, text, target.revision);
    _writing = false;
    if (_disposed) return;
    if (ticket != _opens) {
      // The answer is about an open nobody is on any more; a newer one may
      // have been waiting behind it.
      _catchUp(result, target.ref);
      await _write();
      return;
    }
    // Words a write could not put on disk stay with the saver, so a later
    // try has them and so the document knows it is not settled. Nothing
    // tries again on its own: the same failure would only happen again.
    if (result is store.IoFailure && _pending == null) _pending = text;
    _adopt(result, target.ref);
    if (_writable) await _write();
  }

  /// Whether a write may go out now. A conflicted file takes nothing until
  /// the user decides what to do with it, and a failed one is not written
  /// again until something changes.
  bool get _writable => _state is! SaveConflict && _state is! SaveFailed;

  /// The store's answer to one write, with an exception it was not supposed
  /// to throw turned into the failure it is. A throw that got out would
  /// leave the saver believing a write was still going and hand the error to
  /// every later flush.
  Future<store.SaveResult> _put(
    DocumentRef ref,
    String text,
    Revision expected,
  ) async {
    try {
      return await _store.save(ref, text, expected: expected);
    } on Object catch (error) {
      log.e('save ${ref.path}', error);
      return store.IoFailure('$error');
    }
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
        _undo.keep(receipt);
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

  /// Puts the version before the last save back, through the store, so the
  /// undo is itself a save: it is refused if the file changed underneath and
  /// it is recorded like any other write.
  ///
  /// Waits for a draft on its way out: there is nothing to undo to while the
  /// newest text is still going to disk.
  ///
  /// It is a write like any other to whatever is waiting for the file, too:
  /// a flush, a hold and the closing window wait for the undo, and for the
  /// draft typed while it was going out.
  Future<UndoResult> undo() {
    final target = _target;
    final entry = _undo.newest;
    if (target == null ||
        entry == null ||
        _held ||
        _writing ||
        _pending != null) {
      return Future<UndoResult>.value(const UndoRefused());
    }
    final undoing = _undoTo(entry, target);
    // What is kept here can only complete, never fail: a future left here
    // with an error would throw again at every later flush.
    _inFlight = undoing.then<void>((_) {}, onError: (Object _) {});
    return undoing;
  }

  Future<UndoResult> _undoTo(store.Receipt entry, _Target target) async {
    final resting = _state;
    _writing = true;
    _set(const Saving());
    final ticket = _opens;
    final result = await _put(target.ref, entry.before, entry.committed);
    _writing = false;
    if (_disposed) return const UndoRefused();
    if (ticket != _opens) {
      // The answer is about an open nobody is on any more, and a draft of
      // the document open now may have been waiting behind it.
      _catchUp(result, target.ref);
      await _write();
      return const UndoRefused();
    }
    if (_outOfDate(result, target)) {
      _set(resting);
      await _write();
      return const UndoRefused();
    }
    final outcome = _undone(result, entry, target.ref);
    if (_writable) await _write();
    return outcome;
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
        _undo.tookBack(entry, receipt);
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

  /// Nothing is written while the file is conflicted, so a draft that was
  /// waiting its turn is waiting for nothing. Remembering it would refuse
  /// every undo for the life of the document.
  void _conflicted() {
    _pending = null;
    _set(const SaveConflict());
  }

  void _set(SaveState state) {
    if (_disposed) return;
    // A draft still waiting its turn is not saved, whatever the write that
    // just landed did with the text before it. Saying Saved here would tell
    // the user the file holds words it does not hold yet.
    _state = state is Saved && _pending != null ? const Unsaved() : state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
