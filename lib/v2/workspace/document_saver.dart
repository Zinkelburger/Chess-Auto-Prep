import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart';
import '../diagnostics/log.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/pgn_document_store.dart' as store;
import '../ui/file_names.dart';
import 'session_results.dart';

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
    _adopt(result, target.ref, draft.scope);
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

  /// What the store's answer to a write under [scope] means for the file.
  void _adopt(store.SaveResult result, DocumentRef ref, EditScope scope) {
    switch (result) {
      case store.Saved(:final receipt):
        _target = (ref: ref, revision: receipt.committed);
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

  Future<UndoResult> _undoTo(KeptSave entry, _Target target) async {
    final resting = _state;
    _writing = true;
    _set(const Saving());
    final ticket = _opens;
    // A version this store itself recorded, going back to the file it came
    // from: there is no edit here whose games could be named.
    final result = await _put(
      target.ref,
      entry.receipt.before,
      entry.receipt.committed,
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
  ///
  /// [name] is what the user typed, and a chapter's own name suggests it, so
  /// it can hold anything: what a file cannot be called is replaced
  /// ([importedName]), and the copy is always one file beside the original,
  /// never a folder of its own. The answer names the file written.
  Future<CopyResult> copyAside(
    Chapter chapter, {
    required DocumentRef beside,
    required String name,
  }) async {
    final base = p.extension(name) == '.pgn' ? p.withoutExtension(name) : name;
    final original = p.basenameWithoutExtension(beside.path);
    final file = '${importedName(base, fallback: '$original copy')}.pgn';
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

/// When a draft goes to the disk: the wait after the last edit, and what is
/// on its way once it is over.
///
/// An edit starts the wait, every edit inside it puts the whole of it back,
/// and the write goes out once when it runs out, with the newest text: a
/// burst of moves is one write, not a queue of stale snapshots. Anything
/// that needs the file now — opening another document, a rename, the window
/// closing — [flush]es, which ends the wait at once and answers when nothing
/// is on its way any more. This owns the timing; what is written, and what
/// the store's answer means, is the saver's.
final class SaveClock {
  SaveClock({required this.delay});

  /// How long the file waits after the last edit before it is written.
  final Duration delay;

  /// The clock a draft is waiting on, and the wait itself. Both are null
  /// when nothing is waiting.
  Timer? _timer;
  Completer<void>? _waiting;

  /// The write going out and everything that collapses behind it, so the
  /// app can wait for the file to hold the draft before it closes.
  Future<void>? _inFlight;

  /// Whether a draft is waiting for its second to run out.
  bool get isWaiting => _waiting != null;

  /// A draft was typed. [write] goes out when the wait is over; an edit
  /// while one is already waiting puts the whole wait back instead.
  void edited(Future<void> Function() write) {
    if (_waiting != null) {
      _restart();
      return;
    }
    waitsFor(_waitThenWrite(write));
  }

  /// [work] is what the file is waiting for now — a hold for a rename, or an
  /// undo — so a [flush] waits for the whole of it rather than for a write
  /// that finished before it began.
  ///
  /// What is kept here can only complete, never fail: work that throws is
  /// its caller's to handle, and a failed future left here would throw again
  /// at every later flush.
  void waitsFor<T>(Future<T> work) {
    _inFlight = work.then<void>((_) {}, onError: (Object _) {});
  }

  /// Ends the wait and answers when nothing is on its way any more: the
  /// write in flight, the one that collapsed behind it, and a hold that is
  /// keeping both waiting. A write that was refused or failed also ends it.
  Future<void> flush() {
    hurry();
    return _inFlight ?? Future<void>.value();
  }

  /// Ends the wait, if there is one, without waiting for what it starts.
  /// The wait is always ended rather than dropped: a flush is waiting on it.
  void hurry() {
    _timer?.cancel();
    _timer = null;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<void> _waitThenWrite(Future<void> Function() write) async {
    final waiting = _waiting = Completer<void>();
    // No wait at all is no clock at all: the draft goes out on the next
    // turn, and nothing is left ticking for a test's widget tree to trip on.
    if (delay == Duration.zero) {
      hurry();
    } else {
      _restart();
    }
    await waiting.future;
    await write();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(delay, hurry);
  }
}

/// Words waiting for the disk and the games the edits that made them wrote.
typedef Draft = ({String text, EditScope scope});

/// The one draft waiting to be written, and what it is allowed to change.
///
/// Only one write goes out at a time, so edits made during one collapse into
/// a single draft of the newest words. The scope has to collapse with them:
/// the earlier edit is in those words too, and the store checks a save
/// against the file, not against the draft that never reached it.
final class SaveQueue {
  Draft? _waiting;

  bool get isEmpty => _waiting == null;

  /// Words the user has just typed. They are the newest there are, so they
  /// are what gets written, under a scope covering this edit and whatever
  /// was already waiting.
  void typed(String text, EditScope scope) {
    final waiting = _waiting;
    _waiting = (
      text: text,
      scope: waiting == null ? scope : scopeOfBoth(waiting.scope, scope),
    );
  }

  /// A draft the store did not take, coming back. Words typed while it was
  /// out are newer and win, and they take this draft's scope with them: the
  /// file still holds the version both of them were typed over. The draft
  /// coming back is the earlier edit, and the words waiting were worked out
  /// on what it made, so it goes first.
  void returned(Draft draft) {
    final waiting = _waiting;
    _waiting = waiting == null
        ? draft
        : (text: waiting.text, scope: scopeOfBoth(draft.scope, waiting.scope));
  }

  /// The draft to write now, and the queue is empty again; null when nothing
  /// is waiting.
  Draft? take() {
    final waiting = _waiting;
    _waiting = null;
    return waiting;
  }

  /// Lets go of whatever is waiting: another document was opened, or nothing
  /// more will be written to this one until the user decides what to do.
  void clear() => _waiting = null;
}

/// A save that can be taken back: the store's receipt for it, and the scope
/// it was written under — which games of the version the receipt says it
/// replaced the save changed. Kept in memory with the receipt, for as long
/// as the receipt is.
typedef KeptSave = ({store.Receipt receipt, EditScope scope});

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
      ),
      scope: previous.scope,
    );
  }
}

// What a document's file is doing, and what an undo did to it.
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
      this is! DocumentReadOnly;

  /// Whether a write may go out now: a failed file is written again with the
  /// next edit or the next flush, and [takesWords] covers the rest.
  bool get writable => takesWords && this is! SaveFailed;
}

sealed class UndoResult {
  const UndoResult();
}

/// The file is back at [text]; the caller reads its document from it again.
final class Restored extends UndoResult {
  const Restored(this.text);

  final String text;
}

/// Nothing was undone, and the history is as it was. [reason] is a sentence
/// for the user when there is more to say than "not now".
final class UndoRefused extends UndoResult {
  const UndoRefused([this.reason]);

  final String? reason;
}

/// An undo asked for a version this store never kept. The file was not
/// touched, so the document is no less saved than it was.
const undoNotKept = UndoRefused(
  'Could not go back: that version is not among the ones kept for this file.',
);

/// Nothing goes back while a stopped save is waiting to be dealt with: the
/// file holds a version the words on screen were never written over.
const undoFrozen = UndoRefused(
  'The last save was stopped, so there is nothing to take back yet. Save a '
  'copy or reload first.',
);
