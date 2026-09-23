import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart';
import '../diagnostics/log.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/pgn_document_store.dart' as store;
import 'save_clock.dart';
import 'save_queue.dart';
import 'save_state.dart';
import 'session_results.dart';
import 'undo_history.dart';

typedef _Target = ({DocumentRef ref, Revision revision});

/// Keeps one document's file matching the draft the user is editing.
///
/// Saves are settled, not instant: the [SaveClock] says when a draft goes
/// out, and anything that needs the file now [flush]es. Only one write is in
/// flight at a time and edits made during it collapse into a single pending
/// save, so there is never a queue of stale snapshots. Undo is the store's
/// own receipts played backwards; this owner never remembers a version
/// itself.
final class DocumentSaver extends ChangeNotifier {
  DocumentSaver(this._store, {Duration delay = const Duration(seconds: 1)})
    : _clock = SaveClock(delay: delay);

  final store.PgnDocumentStore _store;

  /// The second a draft waits before it is written, and what is on its way
  /// once it is over.
  final SaveClock _clock;

  _Target? _target;
  SaveState _state = const Saved();
  final _pending = SaveQueue();
  bool _writing = false;
  final _undo = UndoHistory();
  int _opens = 0;
  bool _disposed = false;

  /// What a rename, move or delete of the open file is doing to the autosave.
  _Hold _hold = _Hold.none;

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
    _clock.hurry();
    _undo.clear();
    _set(readOnly == null ? const Saved() : DocumentReadOnly(readOnly));
  }

  /// Takes [text] as the draft to write, unless this saver has stopped
  /// writing the file: conflicted, stopped, or not writable at all. Nothing
  /// is remembered here then — the words are on the screen, where Save a
  /// copy can have them — and the state says the document is not [settled].
  void save(String text, EditScope scope) {
    if (!_state.takesWords) return;
    _pending.typed(text, scope);
    _set(const Unsaved());
    _start();
  }

  /// Ends the wait and answers when nothing is on its way any more; see
  /// [SaveClock.flush]. Closing the window, losing focus and opening another
  /// document wait for this, so an edit made a moment before is not cut off.
  /// Whether the words arrived is [settled].
  Future<void> flush() => _clock.flush();

  /// Runs [action] against the revision the file has now, with the file held
  /// still: the draft waiting on the clock is written first, and a save asked
  /// for while [action] runs waits behind it. Answers null when there is
  /// nothing open or another hold is running.
  ///
  /// This is how a rename, move or delete of the open chapter is serialised
  /// with autosave. The alternative — letting the save go and renaming
  /// afterwards — would leave the rename racing an answer it cannot see, and
  /// a lost race means the user is told their file changed on disk when the
  /// only thing that wrote it was this app.
  Future<T?> holdStill<T>(Future<T> Function(Revision revision) action) {
    if (_hold != _Hold.none || _disposed) return Future<T?>.value();
    _hold = _Hold.settling;
    final held = _holding(action);
    _clock.waitsFor(held);
    return held;
  }

  Future<T?> _holding<T>(Future<T> Function(Revision revision) action) async {
    try {
      // The words waiting on the clock were typed into this file, so they go
      // to it before [action] renames, moves or deletes it. Written
      // afterwards they would go to a name that has moved, or — when the file
      // was deleted and the document closed with it — to no file at all,
      // leaving the last edit in nothing the user can open again.
      await flush();
      _hold = _Hold.held;
      final target = _target;
      if (_disposed || target == null) return null;
      return await action(target.revision);
    } finally {
      _hold = _Hold.none;
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
    _clock.hurry();
    _undo.clear();
    _set(const Saved());
  }

  /// Starts the clock on the draft, or restarts it when one is already
  /// waiting. A draft typed during a write, or while the file is held,
  /// waits for neither clock: it goes out as soon as the write or the hold
  /// is over.
  void _start() {
    if (_hold != _Hold.none || _writing || _disposed) return;
    _clock.edited(_write);
  }

  /// The one gate on writing: the end of the wait, the retry after a
  /// failure and the end of a hold for a rename all come through here, so a
  /// document this saver stopped writing cannot be written by any of them.
  Future<void> _write() async {
    final target = _target;
    if (_disposed || !_state.writable || _writing || target == null) return;
    if (_hold == _Hold.held || _pending.isEmpty) return;
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
    // edit; see [SaveStopped] and [SaveConflict] for what happens to the
    // others.
    if (result is store.IoFailure) _pending.returned(draft);
    _adopt(result, target.ref);
    await _write();
  }

  /// Whether this saver is still writing this document at all.
  bool get takesWords => _state.takesWords;

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
    // By path: two chapters of one file are one file on disk, and the
    // revision a write committed is that file's.
    if (target == null || target.ref.path != ref.path) return;
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
        _stopWriting(const SaveConflict());
      case store.SaveRefused():
        _set(const SaveStopped());
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
    if (_clock.isWaiting) await flush();
    final target = _target;
    final entry = _undo.newest;
    if (_state is SaveStopped) return undoFrozen;
    if (_disposed ||
        target == null ||
        entry == null ||
        _hold != _Hold.none ||
        _writing ||
        !_pending.isEmpty) {
      return const UndoRefused();
    }
    final undoing = _undoTo(entry, target);
    _clock.waitsFor(undoing);
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
        _stopWriting(const SaveConflict());
        return const UndoRefused();
      case store.SaveRefused():
        _set(const SaveStopped());
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

  void _set(SaveState state) {
    if (_disposed) return;
    // A draft still waiting its turn is not saved, whatever the write that
    // just landed did with the text before it. Saying Saved here would tell
    // the user the file holds words it does not hold yet.
    _state = state is Saved && !_pending.isEmpty ? const Unsaved() : state;
    notifyListeners();
  }

  /// Writes [chapter] into a new file next to [beside], under [name].
  ///
  /// This is the one way out of a document that can take no more words — a
  /// save the store stopped, a file this app may not write, a conflict the
  /// user does not want to lose their draft to. It replaces nothing: the
  /// name being taken is a result, never permission to overwrite.
  Future<CopyResult> copyAside(
    Chapter chapter, {
    required DocumentRef beside,
    required String name,
  }) async {
    final file = p.extension(name) == '.pgn' ? name : '$name.pgn';
    final target = DocumentRef(p.join(p.dirname(beside.path), file));
    return switch (await _store.create(target, writeChapter(chapter))) {
      store.Created() => CopySaved(file),
      store.Collision() => const CopyNameTaken(),
      store.IoFailure(:final detail) => CopyFailed(detail),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _clock.hurry();
    super.dispose();
  }
}

/// What a rename, move or delete of the open file is doing to the autosave:
/// [none] is the usual state; in [settling] the draft on the clock is going
/// to the file before the change takes it, and writes still go out, but no
/// second hold may begin; in [held] the change itself is running and nothing
/// is written until it is over.
enum _Hold { none, settling, held }
