import 'dart:async';

import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/pgn_document_store.dart' as store;
import 'save_queue.dart';
import 'save_state.dart';
import 'undo_history.dart';

typedef _Target = ({DocumentRef ref, Revision revision});

/// Keeps one document's file matching the draft the user is editing.
///
/// Saves are settled, not instant: an edit starts a short clock, every edit
/// inside it restarts the clock, and the file is written once when it runs
/// out, with the newest text. A burst of moves is one write, not a queue of
/// stale snapshots. Anything that needs the file now — opening another
/// document, a rename, the window closing, losing focus — [flush]es, which
/// ends the wait at once. Only one write is in flight at a time and edits
/// made during it collapse into a single pending save. Undo is the store's
/// own receipts played backwards; this owner never remembers a version
/// itself.
final class DocumentSaver extends ChangeNotifier {
  DocumentSaver(this._store, {this.delay = const Duration(seconds: 1)});

  /// How long the file waits after the last edit before it is written.
  final Duration delay;

  final store.PgnDocumentStore _store;
  _Target? _target;
  SaveState _state = const Saved();
  final _pending = SaveQueue();
  bool _writing = false;

  /// The clock a draft is waiting on, and the wait itself. Both are null
  /// when nothing is waiting.
  Timer? _clock;
  Completer<void>? _waiting;

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

  /// Whether the file holds the words the user has typed. False while a
  /// draft waits for its clock, while a write is going out, while a draft
  /// waits behind one, and for as long as a save has been stopped or has
  /// failed: those leave words on the screen that are in no file. A document
  /// that opened to read is settled — it took no words to lose. Closing the
  /// window asks this, because [flush] only says that nothing is on its way,
  /// not that anything arrived.
  bool get settled =>
      (_state is Saved || _state is DocumentReadOnly) && _pending.isEmpty;

  /// The file being written, for a log line or a sentence about it.
  String? get documentPath => _target?.ref.path;

  /// A document was opened. It is the one this saver writes from now on,
  /// and nothing of the last one is carried over. [readOnly] is why the
  /// file may not be written at all, or null when it may.
  ///
  /// The draft of the document being replaced must already be on disk, which
  /// is why the caller waits for [flush] first: a draft waiting behind a hold
  /// belongs to the file it was typed into, and this cannot write it there
  /// once the target has changed.
  void opened(DocumentRef ref, Revision revision, {String? readOnly}) {
    _opens++;
    _target = (ref: ref, revision: revision);
    _pending.clear();
    _hurry();
    _undo.clear();
    _set(readOnly == null ? const Saved() : DocumentReadOnly(readOnly));
  }

  /// Takes [text] as the draft to write, unless this saver has stopped
  /// writing the file: conflicted, stopped, or not writable at all. Nothing
  /// is remembered here then — the words are on the screen, where Save a
  /// copy can have them — and the state says the document is not [settled].
  void save(String text, EditScope scope) {
    if (!takesWords) return;
    _pending.typed(text, scope);
    _set(const Unsaved());
    _start();
  }

  /// Ends the wait and answers when nothing is on its way any more: the
  /// write in flight, the one that collapsed behind it, and a hold that is
  /// keeping both waiting. Closing the window, losing focus and opening
  /// another document wait for this, so an edit made a moment before is not
  /// cut off. Whether the words arrived is [settled]; a write that was
  /// refused or failed also ends the wait.
  Future<void> flush() {
    _hurry();
    return _inFlight ?? Future<void>.value();
  }

  /// Runs [action] against the revision the file has now, with the file held
  /// still: the write on its way out finishes first, and a save asked for
  /// while [action] runs waits behind it. Answers null when there is nothing
  /// open or another hold is running.
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
    _pending.clear();
    _hurry();
    _undo.clear();
    _set(const Saved());
  }

  /// Starts the clock on the draft, or restarts it when one is already
  /// waiting. A draft typed during a write, or while the file is held,
  /// waits for neither clock: it goes out as soon as the write or the hold
  /// is over.
  void _start() {
    if (_held || _writing || _disposed) return;
    if (_waiting != null) {
      _restartClock();
      return;
    }
    _inFlight = _waitThenWrite();
  }

  Future<void> _waitThenWrite() async {
    final waiting = _waiting = Completer<void>();
    // No wait at all is no clock at all: the draft goes out on the next
    // turn, and nothing is left ticking for a test's widget tree to trip on.
    if (delay == Duration.zero) {
      _hurry();
    } else {
      _restartClock();
    }
    await waiting.future;
    await _write();
  }

  void _restartClock() {
    _clock?.cancel();
    _clock = Timer(delay, _hurry);
  }

  /// Ends the wait, if there is one. The draft goes out now — or, when the
  /// document was closed or replaced meanwhile, the write finds nothing
  /// waiting and does nothing. The wait is always ended rather than dropped:
  /// a flush is waiting on it.
  void _hurry() {
    _clock?.cancel();
    _clock = null;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  /// The one gate on writing: the end of the wait, the retry after a
  /// failure and the end of a hold for a rename all come through here, so a
  /// document this saver stopped writing cannot be written by any of them.
  Future<void> _write() async {
    final target = _target;
    if (_disposed || !_writable || _held || _writing || target == null) return;
    if (_pending.isEmpty) return;
    final draft = _pending.take()!;
    _writing = true;
    _set(const Saving());
    final ticket = _opens;
    final result = await _put(
      target.ref,
      draft.text,
      target.revision,
      draft.scope,
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
    // Only a write the disk refused comes back to be tried with the next
    // edit; see [_stopped] for what happens to the others.
    if (result is store.IoFailure) _pending.returned(draft);
    _adopt(result, target.ref);
    await _write();
  }

  /// Whether a write may go out now: a failed file is written again with
  /// the next edit, and [takesWords] covers the rest.
  bool get _writable => takesWords && _state is! SaveFailed;

  /// Whether this saver is still writing this document at all. A stopped
  /// save freezes it: the words stay on the screen, where Save a copy can
  /// have them, and nothing else goes to disk under a scope that does not
  /// name their games. A conflicted file and one this app may not write are
  /// the same to whoever is about to tell the user that waiting will help.
  bool get takesWords =>
      _state is! SaveConflict &&
      _state is! SaveStopped &&
      _state is! DocumentReadOnly;

  /// The store's answer to one write, with an exception it was not supposed
  /// to throw turned into the failure it is. A throw that got out would
  /// leave the saver believing a write was still going and hand the error to
  /// every later flush.
  Future<store.SaveResult> _put(
    DocumentRef ref,
    String text,
    Revision expected,
    EditScope scope,
  ) async {
    try {
      return await _store.save(ref, text, expected: expected, scope: scope);
    } on Object catch (error) {
      log.e('save ${ref.path}', error);
      return store.IoFailure('$error');
    }
  }

  /// A write that landed after its document was opened again. When it wrote
  /// the file that is open now, the revision it committed is the newest
  /// there is and the next save must expect it. Its receipt belongs to the
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
      case store.SaveRefused():
        _stopped();
      case store.NotWritable(:final detail):
        _stopWriting(DocumentReadOnly(detail));
      // A restore is the only write that can be refused for not being a
      // kept version, and only [_undoTo] makes one; here it is a failure
      // like any other the store could not carry out.
      case store.RestoreRefused(:final detail) ||
          store.IoFailure(:final detail):
        _set(SaveFailed(detail));
    }
  }

  /// Puts the version before the last save back, through the store, so the
  /// undo is itself a save: refused if the file changed underneath, and
  /// recorded like any other write.
  ///
  /// A draft still waiting for its clock goes out first: the edit the user
  /// wants back is the one they just made, and it is not a save until it is
  /// written. Then the undo waits for nothing else; there is nothing to undo
  /// to while newer text is still going to disk. A flush, a hold and the
  /// closing window wait for the undo, and for the draft typed while it went
  /// out.
  ///
  /// Words typed while the undo is being written are newer than the version
  /// being put back, so they win: the draft goes to disk, the undo is
  /// refused, and the version it wrote becomes the next step back.
  Future<UndoResult> undo() async {
    if (_state is SaveStopped) return undoFrozen;
    if (_waiting != null) await flush();
    final target = _target;
    final entry = _undo.newest;
    if (_state is SaveStopped) return undoFrozen;
    if (_disposed ||
        target == null ||
        entry == null ||
        _held ||
        _writing ||
        !_pending.isEmpty) {
      return const UndoRefused();
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
    // A version this store itself recorded, going back to the file it came
    // from: there is no edit here whose games could be named.
    final result = await _put(
      target.ref,
      entry.before,
      entry.committed,
      const RestoredVersion(),
    );
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
    if (result is store.Saved && !_pending.isEmpty) {
      // Typed over: the entry stays where it is, the draft goes out on top
      // of the version just written, and the receipt the draft brings back
      // makes that version the next step back.
      _catchUp(result, target.ref);
      await _write();
      return const UndoRefused();
    }
    final outcome = _undone(result, entry, target.ref, resting);
    await _write();
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

  /// What one answer to a restore means. [resting] is the state the file was
  /// in before the undo went out, which a refused restore goes back to: the
  /// file was not touched, so nothing about it is unsaved because of this.
  UndoResult _undone(
    store.SaveResult result,
    store.Receipt entry,
    DocumentRef ref,
    SaveState resting,
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
      case store.SaveRefused():
        _stopped();
        return const UndoRefused();
      case store.RestoreRefused(:final detail):
        log.w('undo ${ref.path}', detail);
        _set(resting);
        return undoNotKept;
      case store.NotWritable(:final detail):
        _stopWriting(DocumentReadOnly(detail));
        return const UndoRefused();
      case store.IoFailure(:final detail):
        _set(SaveFailed(detail));
        return const UndoRefused();
    }
  }

  /// Nothing more goes out in [state], so a draft waiting its turn is
  /// waiting for nothing. Remembering it would refuse every undo for the
  /// life of the document.
  void _stopWriting(SaveState state) {
    _pending.clear();
    _set(state);
  }

  void _conflicted() => _stopWriting(const SaveConflict());

  /// The store stopped the save. Nothing is taken away: the words are on
  /// the screen and whatever was typed behind this write is still waiting,
  /// so Save a copy has all of them. Nothing more goes to disk until the
  /// user reloads or saves a copy.
  void _stopped() => _set(const SaveStopped());

  void _set(SaveState state) {
    if (_disposed) return;
    // A draft still waiting its turn is not saved, whatever the write that
    // just landed did with the text before it. Saying Saved here would tell
    // the user the file holds words it does not hold yet.
    _state = state is Saved && !_pending.isEmpty ? const Unsaved() : state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hurry();
    super.dispose();
  }
}
