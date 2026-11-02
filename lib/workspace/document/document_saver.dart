import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../diagnostics/log.dart';
import '../../storage/document_ref.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/pending_writes.dart';
import '../../ui/file_names.dart';
import '../book/books.dart';
import '../latest.dart';
import 'save_queue.dart';
import 'session_results.dart';
import 'undo_history.dart';

part 'save_clock.dart';

typedef _Target = ({DocumentRef ref, Revision revision});
typedef _UndoWrite = ({KeptSave entry, _Target target, RestoredVersion scope});

/// Keeps one document's file matching the draft the user is editing.
///
/// Saves are settled, not instant: the [SaveClock] says when a draft goes
/// out, and anything that needs the file now [flush]es. Only one write is in
/// flight at a time and edits made during it collapse into a single pending
/// save, so there is never a queue of stale snapshots. Undo is the store's
/// own receipts played backwards; this owner never remembers a version
/// itself.
final class DocumentSaver extends ChangeNotifier {
  DocumentSaver(
    this._store, {
    Duration delay = const Duration(seconds: 1),
    this.pendingWrites,
    this.books,
  }) : _clock = SaveClock(delay: delay);

  final PendingWrites? pendingWrites;
  final Books? books;

  // A compound publication cannot absorb another edit after an uncertain
  // acknowledgement. Its exact draft and command id must settle first. One
  // fact, so this saver's own write and a command from outside can never
  // both seem to hold it.
  _Barrier? _barrier;
  _UndoWrite? _failedUndo;

  /// A two-file publication must settle before another edit can change its
  /// exact input. The session checks this before changing its shown chapter.
  bool get referencesPending => _barrier != null;

  /// Whether [command], from outside, holds the barrier.
  bool _heldBy(Object command) => switch (_barrier) {
    _ByCommand(command: final holder) => identical(holder, command),
    _ => false,
  };

  /// An undo retry must also put its restored words back on screen. A plain
  /// [flush] cannot do that, so the session retries through its undo command.
  bool get retryNeedsUndo => _failedUndo != null;

  /// An uncertain compound command holds the barrier with no draft to flush:
  /// only reading the chapter again gives the editor a safe input.
  bool get retryNeedsReload =>
      referencesPending && _pending.isEmpty && _failedUndo == null;
  final _copies =
      <
        (DocumentRef, DocumentRef, String),
        PendingObligation<store.CreateResult>
      >{};

  final store.PgnDocumentStore _store;

  /// The second a draft waits before it is written, and what is on its way
  /// once it is over.
  final SaveClock _clock;

  _Target? _target;
  SaveState _state = const Saved();
  final _pending = SaveQueue();
  bool _writing = false;
  final _undo = UndoHistory();
  final _opens = Latest();
  bool _disposed = false;

  /// What a rename, move or delete of the open file is doing to the autosave.
  _Hold _hold = _Hold.none;

  /// Asked when a write finds the open file gone; see [owesMove].
  Future<bool> Function()? _followMove;

  SaveState get state => _state;
  Revision? get revision => _target?.revision;

  /// The opened source, advanced only by our own proven publication chain.
  Revision? get trainingSourceRevision => _trainingSourceRevision;
  Revision? _trainingSourceRevision;
  store.Receipt? get lastReceipt => _lastReceipt;
  store.Receipt? _lastReceipt;

  bool get canUndo => !_undo.isEmpty && _state is! DocumentFollowing;

  /// Whether the file holds the words the user has typed. False while a
  /// draft waits for its clock, while a write is going out, while a draft
  /// waits behind one, and for as long as a save has been stopped or has
  /// failed: those leave words on the screen that are in no file. A document
  /// that opened to read is settled — it took no words to lose — and so is
  /// one waiting to be read again after an edit the store recorded. Closing
  /// the window asks this, because [flush] only says that nothing is on its
  /// way, not that anything arrived.
  bool get settled =>
      (_state is Saved ||
          _state is DocumentReadOnly ||
          _state is DocumentFollowing) &&
      _pending.isEmpty &&
      !referencesPending;

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
    _opens.cancel();
    _target = (ref: ref, revision: revision);
    _lastReceipt = null;
    _trainingSourceRevision = revision;
    _pending.clear();
    _clock.hurry();
    _undo.clear();
    _barrier = null;
    _failedUndo = null;
    _set(readOnly == null ? const Saved() : DocumentReadOnly(readOnly));
  }

  /// Takes [text] as the draft to write, unless this saver has stopped
  /// writing the file: conflicted, stopped, or not writable at all. Nothing
  /// is remembered here then — the words are on the screen, where Save a
  /// copy can have them — and the state says the document is not [settled].
  void save(String text, EditScope scope) {
    if (!takesWords) return;
    // Ordinary edits can supersede an ordinary failed undo. Compound undo
    // keeps admission closed until its exact command has been reconciled.
    _failedUndo = null;
    _pending.typed(text, scope);
    _set(const Unsaved());
    _start();
  }

  /// Ends the wait and answers when nothing is on its way any more; see
  /// [SaveClock.flush]. Closing the window, losing focus and opening another
  /// document wait for this, so an edit made a moment before is not cut off.
  /// Whether the words arrived is [settled].
  ///
  /// A draft the disk refused goes out again first, as a new edit's would:
  /// whoever flushes needs the file now, and nothing else writes it before
  /// the next edit. It is tried once per flush, never on a timer of its own.
  Future<void> flush() {
    if (_state is SaveFailed && !_pending.isEmpty) {
      _set(const Unsaved());
      _start();
    }
    return _clock.flush();
  }

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
  Future<T?> holdStill<T>(
    Future<T> Function(Revision revision) action, {
    Object? continuing,
  }) {
    if (_hold != _Hold.none || _disposed) return Future<T?>.value();
    _hold = _Hold.settling;
    final held = _holding(action, continuing);
    _clock.waitsFor(held);
    return held;
  }

  Future<T?> _holding<T>(
    Future<T> Function(Revision revision) action,
    Object? continuing,
  ) async {
    try {
      // The words waiting on the clock were typed into this file, so they go
      // to it before [action] renames, moves or deletes it. Written
      // afterwards they would go to a name that has moved, or — when the file
      // was deleted and the document closed with it — to no file at all,
      // leaving the last edit in nothing the user can open again.
      await flush();
      _hold = _Hold.held;
      final target = _target;
      final retry =
          continuing != null && _heldBy(continuing) && _pending.isEmpty;
      if (_disposed || target == null || (!settled && !retry)) return null;
      return await action(target.revision);
    } finally {
      _hold = _Hold.none;
      await _write();
    }
  }

  /// Called inside [holdStill] after the accepted source is checked.
  bool beginExternal(Object command, Revision expected) {
    if (_hold != _Hold.held ||
        _disposed ||
        revision != expected ||
        revision?.nativeIdentity != expected.nativeIdentity ||
        (_barrier != null && !_heldBy(command))) {
      return false;
    }
    _barrier = _ByCommand(command);
    _set(const Saving());
    return true;
  }

  /// Receipt, undo and shown words become observable together. [show] updates
  /// the session before saver listeners can observe the new persisted revision.
  void adoptExternal(
    Object command,
    store.Receipt receipt,
    EditScope scope,
    void Function() show,
  ) {
    if (!_heldBy(command) || _disposed) return;
    final target = _target!;
    _barrier = null;
    _received(target.ref, receipt);
    _undo.keep(receipt, scope);
    _state = const Saved();
    show();
    if (!_disposed) notifyListeners();
  }

  /// A lost acknowledgement retains the exact command's edit barrier. If its
  /// editor was superseded, reopening supplies the only safe displayed input.
  void endExternal(
    Object command,
    store.SaveResult result,
    EditScope scope, {
    required bool uncertain,
  }) {
    if (!_heldBy(command) || _disposed) return;
    if (result is store.Saved) {
      // Acknowledged: nothing of the command is left to retry.
      _barrier = null;
      _set(const SaveStopped());
      return;
    }
    if (!uncertain) _barrier = null;
    _adopt(result, _target!.ref, scope);
  }

  /// Lets [command] go without an answer to adopt: the store recorded it and
  /// finishes it itself, after a restart too, or the user gave up on it. Its
  /// barrier took no words, so none are lost, but the chapter on screen may
  /// predate the file and takes none until it is read again. False when
  /// [command] no longer holds this editor.
  bool releaseExternal(Object command, String detail) {
    if (!_heldBy(command) || _disposed) return false;
    log.w('follow ${_target?.ref.path}', detail);
    _barrier = null;
    _set(DocumentFollowing(detail));
    return true;
  }

  /// A namespace-only command keeps the revision and PGN bytes. Until an
  /// uncertain move is acknowledged, keep its editor barrier across retries.
  void resolveExternalMove(
    Object command, {
    String? failure,
    bool uncertain = false,
  }) {
    if (!_heldBy(command) || _disposed) return;
    if (!uncertain) _barrier = null;
    _set(failure == null ? const Saved() : SaveFailed(failure));
  }

  /// A move of the open file that the store recorded and did not finish: the
  /// recovery gate carries it out at a later access, which may be a save's.
  /// A write that then finds the file gone asks [follow] whether the move
  /// took it, having moved the document after it when it could, and goes to
  /// where it is now. Null when no move is owed. It is kept across opening
  /// another document, because [follow] answers for whichever one is open
  /// and the user may come back to the one the move is owed for.
  void owesMove(Future<bool> Function()? follow) => _followMove = follow;

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
    _opens.cancel();
    _target = null;
    _trainingSourceRevision = null;
    _lastReceipt = null;
    _pending.clear();
    _clock.hurry();
    _undo.clear();
    _barrier = null;
    _failedUndo = null;
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
    var target = _target;
    if (_disposed || !_state.writable || _writing || target == null) return;
    if (_hold == _Hold.held || _pending.isEmpty || _barrier is _ByCommand) {
      return;
    }
    final draft = _pending.take()!;
    _writing = true;
    final wasUncertain = _barrier is _OwnWrite;
    _barrier = draft.scope.references != null ? const _OwnWrite() : null;
    _set(const Saving());
    final ticket = _opens.now;
    var result = await _put(
      target.ref,
      draft.text,
      target.revision,
      draft.scope,
    );
    // The file left its name under a move the store recorded, carried out at
    // this very access or followed by the workspace while this write was
    // out. The draft follows it rather than stopping at the name it left;
    // one naming references names the old path, so it stops.
    if (result is store.Conflict &&
        result.current == null &&
        draft.scope.references == null &&
        ticket.current &&
        await _followed(target.ref) &&
        !_disposed &&
        ticket.current) {
      final moved = _target!;
      result = p.equals(moved.ref.path, target.ref.path)
          ? const store.IoFailure('the file is still moving')
          : await _put(moved.ref, draft.text, moved.revision, draft.scope);
      target = moved;
    }
    _writing = false;
    if (_disposed) return;
    if (ticket.overtaken) {
      // The answer is about an open nobody is on any more; a newer one may
      // have been waiting behind it.
      _catchUp(result, target.ref);
      await _write();
      return;
    }
    if (result is store.Saved ||
        (!wasUncertain && result is! store.IoFailure)) {
      _barrier = null;
    }
    // Only a write the disk refused comes back to be tried with the next
    // edit; see [SaveStopped] and [SaveConflict] for what happens to the
    // others.
    if (result is store.IoFailure) _pending.returned(draft);
    _adopt(result, target.ref, draft.scope);
    await _write();
  }

  /// Whether the open document moved on from [wrote], the name a write
  /// found gone: already relocated, or relocated by the owed move's follow.
  Future<bool> _followed(DocumentRef wrote) async {
    if (!p.equals(_target!.ref.path, wrote.path)) return true;
    final follow = _followMove;
    return follow != null && await follow();
  }

  /// Whether this saver is still writing this document at all.
  bool get takesWords => !referencesPending && _state.takesWords;

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
      Future<store.SaveResult> save() =>
          _store.save(ref, text, expected: expected, scope: scope);
      final changesReferences =
          scope.references != null ||
          (scope is RestoredVersion && scope.inverse != null);
      return books != null && changesReferences
          ? await books!.saveReferences(save)
          : await save();
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
      _received(ref, receipt);
      if (!_disposed) notifyListeners();
    }
  }

  void _received(DocumentRef ref, store.Receipt receipt) {
    _target = (ref: ref, revision: receipt.committed);
    _lastReceipt = receipt;
    final source = _trainingSourceRevision;
    final before = receipt.beforeRevision;
    if (source != null &&
        source == before &&
        source.nativeIdentity == before.nativeIdentity &&
        (source.nativeIdentity == null ||
            receipt.committed.nativeIdentity != null)) {
      _trainingSourceRevision = receipt.committed;
    }
  }

  /// What the store's answer to a write under [scope] means for the file.
  void _adopt(store.SaveResult result, DocumentRef ref, EditScope scope) {
    switch (result) {
      case store.Saved(:final receipt):
        _received(ref, receipt);
        _undo.keep(receipt, scope);
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
    if (_state is DocumentFollowing) return undoBehind;
    if (_clock.isWaiting) await flush();
    final target = _target;
    final entry = _undo.newest;
    if (_state is SaveStopped) return undoFrozen;
    if (_disposed ||
        target == null ||
        entry == null ||
        _hold != _Hold.none ||
        _barrier is _ByCommand ||
        _writing ||
        !_pending.isEmpty) {
      return const UndoRefused();
    }
    final write =
        _failedUndo ??
        (
          entry: entry,
          target: target,
          scope: RestoredVersion(inverse: entry.receipt.compound),
        );
    final undoing = _undoTo(write);
    _clock.waitsFor(undoing);
    return undoing;
  }

  Future<UndoResult> _undoTo(_UndoWrite write) async {
    final (:entry, :target, :scope) = write;
    final resting = _state;
    final wasUncertain = _failedUndo != null;
    final compound = scope.inverse != null;
    _writing = true;
    _barrier = compound ? const _OwnWrite() : null;
    _set(const Saving());
    final ticket = _opens.now;
    // A version this store itself recorded, going back to the file it came
    // from: there is no edit here whose games could be named.
    final result = await _put(
      target.ref,
      entry.receipt.before,
      entry.receipt.committed,
      scope,
    );
    _writing = false;
    if (_disposed) return const UndoRefused();
    if (ticket.overtaken) {
      // The answer is about an open nobody is on any more, and a draft of
      // the document open now may have been waiting behind it.
      _catchUp(result, target.ref);
      await _write();
      return const UndoRefused();
    }
    if (result is store.IoFailure && _pending.isEmpty) _failedUndo = write;
    if (result is store.Saved ||
        (!wasUncertain && result is! store.IoFailure)) {
      _barrier = null;
      _failedUndo = null;
    }
    if (_outOfDate(result, target)) {
      _set(resting);
      await _write();
      return const UndoRefused();
    }
    if (result is store.Saved && !_pending.isEmpty) {
      // Typed over: the entry stays where it is, the draft goes out on top
      // of the version just written, and the receipt the draft brings back
      // makes that version the next step back. The draft was worked out on
      // the version the undo took away, so against the file it also changes
      // the games the undone edit changed, and says so.
      final typed = _pending.take()!;
      _pending.typed(typed.text, scopeOfBoth(entry.scope, typed.scope));
      _catchUp(result, target.ref);
      await _write();
      return const UndoRefused();
    }
    final outcome = _undone(result, entry.receipt, target.ref, resting);
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
        _received(ref, receipt);
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

  /// Writes [chapter] into a new file next to [beside], or in the folder
  /// [into] when given, under [name].
  ///
  /// This is the one way out of a document that can take no more words — a
  /// save the store stopped, a file this app may not write, a conflict the
  /// user does not want to lose their draft to. It replaces nothing: the
  /// name being taken is a result, never permission to overwrite.
  ///
  /// [name] is what the user typed, and a chapter's own name suggests it, so
  /// it can hold anything: what a file cannot be called is replaced
  /// ([importedName]), and the copy is always one file, never a folder of
  /// its own. The answer names the file written.
  Future<CopyResult> copyAside(
    Chapter chapter, {
    required DocumentRef beside,
    required String name,
    String? into,
  }) async {
    final base = p.extension(name) == '.pgn' ? p.withoutExtension(name) : name;
    final original = p.basenameWithoutExtension(beside.path);
    final file = '${importedName(base, fallback: '$original copy')}.pgn';
    final target = DocumentRef(p.join(into ?? p.dirname(beside.path), file));
    final text = writeChapter(chapter);
    final pending = pendingWrites;
    final store.CreateResult result;
    if (pending == null) {
      result = await _store.create(target, text);
    } else {
      // The name has been accepted: this publication now outlives its dialog
      // or navigation request. A name dialog still awaiting input registers
      // nothing. Only retrying this exact source snapshot and destination
      // may clear its failed outcome; an unrelated successful copy may not.
      final key = (beside, target, text);
      final operation = _copies.putIfAbsent(key, () {
        var uncertain = false;
        return pending.accept(
          resource: this,
          label: 'Copy $file',
          work: () async {
            try {
              final result = await _store.create(target, text);
              if (result is store.IoFailure) uncertain = true;
              return result;
            } on Object {
              uncertain = true;
              rethrow;
            }
          },
          problem: (value) => switch (value) {
            store.Created() => null,
            // A first collision confirms that this command wrote nothing.
            // After an uncertain result, existence cannot prove our copy won.
            store.Collision() when !uncertain => null,
            store.Collision() =>
              'A file named $file already exists; the copy was not confirmed.',
            store.IoFailure(:final detail) => detail,
          },
        );
      });
      result = await operation.run();
      if (operation.committed) _copies.remove(key);
    }
    return switch (result) {
      store.Created() => CopySaved(file),
      store.Collision() => const CopyNameTaken(),
      store.IoFailure(:final detail) => CopyFailed(detail),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _opens.close();
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

/// Who keeps new edits out while a publication naming two files settles.
sealed class _Barrier {
  const _Barrier();
}

/// This saver's own write naming references, going out or unanswered.
final class _OwnWrite extends _Barrier {
  const _OwnWrite();
}

/// A command from outside, between [DocumentSaver.beginExternal] and the
/// answer that lets it go.
final class _ByCommand extends _Barrier {
  const _ByCommand(this.command);

  final Object command;
}

// What a document's file is doing.
//
// The words the workspace reads off the saver: its widgets switch on these
// and write the sentences, and nothing here knows how a file is written.

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

/// The store stopped the save because the text would have changed a game
/// the edit never touched. Nothing is taken away: the words are still on the
/// screen, where Save a copy can have them, the file is as it was, and
/// nothing more goes to disk until the user reloads or saves a copy.
///
/// A conflict for the user's purposes — reload or save a copy — but it is
/// the app's mistake, not another writer's, so it says something else. The
/// store has already put the game it would have changed in the log.
final class SaveStopped extends SaveState {
  const SaveStopped();
}

/// Someone else wrote the file. The draft is kept and nothing more is
/// written until the user chooses what to do with it.
final class SaveConflict extends SaveState {
  const SaveConflict();
}

/// The file is not one this app may write at all. Nothing was edited and
/// nothing will be: the document opened to read.
final class DocumentReadOnly extends SaveState {
  const DocumentReadOnly(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// The file took an edit made elsewhere — a line move the store recorded
/// and finishes itself, or one the user gave up on — so the chapter on screen
/// may predate what it holds. Nothing typed is lost and nothing more is
/// written until it is read again.
final class DocumentFollowing extends SaveState {
  const DocumentFollowing(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// What a state means for the words still to be written.
extension WordsIn on SaveState {
  /// Whether the saver is still writing this document at all. A stopped save
  /// freezes it: the words stay on the screen, where Save a copy can have
  /// them, and nothing else goes to disk under a scope that does not name
  /// their games. A conflicted file and one this app may not write are the
  /// same to whoever is about to tell the user that waiting will help.
  bool get takesWords =>
      this is! SaveConflict &&
      this is! SaveStopped &&
      this is! DocumentReadOnly &&
      this is! DocumentFollowing;

  /// Whether a write may go out now: a failed file is written again with the
  /// next edit or the next flush, and [takesWords] covers the rest.
  bool get writable => takesWords && this is! SaveFailed;
}
