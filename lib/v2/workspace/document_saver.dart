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
  final _undo = <store.Receipt>[];
  int _opens = 0;
  bool _disposed = false;
  bool _held = false;
  Future<void>? _running;

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
    _start();
  }

  /// Runs [action] against the revision the file has now, with the file held
  /// still: a save on its way out finishes first, and a save asked for while
  /// [action] runs waits behind it and goes to wherever the document ends up.
  /// Answers null when there is nothing open or another hold is running.
  ///
  /// This is how a rename, move or delete of the open chapter is serialised
  /// with autosave. The alternative — letting the save go and renaming
  /// afterwards — would leave the rename racing an answer it cannot see, and
  /// a lost race means the user is told their file changed on disk when the
  /// only thing that wrote it was this app.
  Future<T?> holdStill<T>(Future<T> Function(Revision revision) action) async {
    if (_held || _disposed) return null;
    _held = true;
    try {
      // At most twice: nothing new starts while the file is held.
      while (_writing) {
        await _running;
      }
      final target = _target;
      if (_disposed || target == null) return null;
      return await action(target.revision);
    } finally {
      _held = false;
      _start();
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

  void _start() {
    if (_disposed) return;
    _running = _write();
  }

  Future<void> _write() async {
    final target = _target;
    final text = _pending;
    if (_held || _writing || target == null || text == null) return;
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
      // The answer is about a document nobody has open now; a newer one may
      // have been waiting behind it.
      _start();
      return;
    }
    _adopt(result, target.ref);
    if (_state is! SaveConflict) _start();
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
        _set(const SaveConflict());
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
    if (target == null ||
        _undo.isEmpty ||
        _held ||
        _writing ||
        _pending != null) {
      return const UndoRefused();
    }
    final entry = _undo.last;
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
    return _undone(result, entry, target.ref);
  }

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
        _set(const SaveConflict());
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
