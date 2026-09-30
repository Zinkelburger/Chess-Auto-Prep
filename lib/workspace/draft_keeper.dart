import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart';
import '../diagnostics/log.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
import '../storage/viewer_drafts.dart';
import '../ui/status_bar.dart' show StatusAction;
import 'document_history.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'session_results.dart';

/// Keeps a copy of the edits the viewer holds unsaved, and offers it back
/// the next time its file opens after a crash or a close.
///
/// A checkpoint is written a second after the held edits last changed,
/// one write per burst, its text encoded off the UI isolate; it is dropped
/// once the edits are saved (the file took them) or discarded. Edits another
/// reading of their file put away leave it on disk, offered back. The offer is
/// one line in the status bar with `Restore unsaved edits`: restoring puts
/// the edits back as held edits against the revision they were made on. A
/// draft of a file that changed since cannot be restored over it; the offer
/// is then to save the draft beside the file as a copy.
///
/// A checkpoint on disk is only ever replaced or dropped by the visit that
/// made the edits in it: a visit's first held edit sets aside a checkpoint
/// it did not write (an earlier session's, or a tab closed on its edits),
/// unless the edits are that checkpoint's, restored by a tab.
///
/// Only a document shown game by game — a collection in the viewer, a study
/// chapter — is kept: that is where edits are held.
final class DraftKeeper {
  DraftKeeper({
    required DocumentSession session,
    required DocumentSaver saver,
    required ViewerDrafts drafts,
    required this.say,
    this.delay = const Duration(seconds: 1),
  }) : _session = session,
       _saver = saver,
       _drafts = drafts {
    _session.addListener(_changed);
    _saver.addListener(_changed);
  }

  final DocumentSession _session;
  final DocumentSaver _saver;
  final ViewerDrafts _drafts;

  /// Puts the offer in the status bar, or takes it down.
  final void Function(String? sentence, {StatusAction? action, bool problem})
  say;
  final Duration delay;

  /// The file on the board as last seen, and whether it held edits then.
  String? _path;
  bool _held = false;

  /// Whether the file was shown one game at a time, where a draft is offered.
  bool _oneGame = false;

  /// Whether this visit to [_path] made held edits, which makes the
  /// checkpoint on disk its own to replace, and to drop once they are saved
  /// or discarded.
  bool _owns = false;

  /// For each file whose checkpoint this run wrote and has not dropped, the
  /// file as written: a tab bringing exactly those edits back continues
  /// them instead of setting its own checkpoint aside.
  final _kept = <String, Chapter>{};

  /// The snapshot waiting for its second to pass.
  ({Chapter file, int game, Revision revision, String path})? _waiting;
  Timer? _timer;

  /// Why the checkpoint of each file named could not be written, until one
  /// is or the file needs none.
  final _unkept = <String, String>{};

  /// The draft offered for the open file, until it is restored, replaced
  /// by new edits or its file is left.
  ViewerDraft? _offered;
  ViewerDraft? get offered => _offered;
  bool _disposed = false;

  /// Looks at what is open already: a file opened before the keeper was
  /// is offered its draft too.
  void start() => _changed();

  void _changed() {
    if (_disposed) return;
    final path = _session.source?.path;
    final held = _session.hasHeldEdits;
    final oneGame = _session.game != null;
    if (path != _path) {
      _flush();
      _withdraw();
      _path = path;
      _held = false;
      _owns = false;
      // In turn: a checkpoint the file's edits left as it closed may still
      // be on its way to the disk.
      if (path != null && !held) _inTurn(() => _offer(path));
    } else if (path != null && oneGame && !_oneGame && !held && !_owns) {
      // Read merged and then game by game again: the draft is offered now.
      _inTurn(() => _offer(path));
    }
    _oneGame = oneGame;
    if (held) {
      if (!_owns) _claim();
      _schedule();
    } else if (_held) {
      // Saved or discarded: whatever is waiting is written now, so edits a
      // failed save still owes are not lost to a crash meanwhile.
      _flush();
    }
    _held = held;
    if (!held && _owns && path != null) _ended(path);
  }

  /// The edits this visit held are off the board, as the session says: kept
  /// and saved, or discarded, their checkpoint goes. Put away by another
  /// reading of the file, it stays on disk and is offered back.
  void _ended(String path) {
    switch (_session.heldEditsEnded) {
      case HeldEditsEnded.kept when !_saver.settled:
        return;
      case HeldEditsEnded.kept || HeldEditsEnded.discarded:
        _kept.remove(path);
        _inTurn(() => _drop(path));
      case HeldEditsEnded.dropped || null:
        _inTurn(() => _offer(path));
    }
    _owns = false;
  }

  /// This visit's first held edit. A checkpoint already on disk may hold
  /// work these edits do not, so it is set aside whole before they replace
  /// it — unless they are that checkpoint's own edits, parked in a tab.
  void _claim() {
    _owns = true;
    final path = _path!;
    final ours = identical(_shownFile(), _kept[path]);
    _withdraw();
    if (!ours) _setAside(path);
  }

  Chapter? _shownFile() {
    final shown = _session.retainedDraft?.shown;
    return shown == null ? null : shown.view?.file ?? shown.chapter;
  }

  void _schedule() {
    final draft = _session.retainedDraft;
    final game = _session.game;
    final path = _path;
    if (draft == null || game == null || path == null) return;
    _waiting = (
      file: draft.shown.view?.file ?? draft.shown.chapter,
      game: game,
      revision: draft.revision,
      path: path,
    );
    _timer?.cancel();
    _timer = Timer(delay, _flush);
  }

  /// Writes the snapshot waiting, if there is one, now.
  void _flush() {
    _timer?.cancel();
    _timer = null;
    final waiting = _waiting;
    _waiting = null;
    if (waiting == null) return;
    _kept[waiting.path] = waiting.file;
    _inTurn(() => _keep(waiting));
  }

  /// Writes what is waiting now and completes once every checkpoint asked
  /// for is on disk; the window closes after this. Answers which edits are
  /// in no checkpoint and why, or null when every one was written.
  Future<String?> settle() async {
    _flush();
    await _tail;
    return _unkept.isEmpty ? null : _unkept.values.join('\n');
  }

  /// Completes once the checkpoint of the edits [path] holds is written,
  /// and answers why it could not be, or null when it is on disk. A tab
  /// asks this before it lets go of the edits it holds.
  Future<String?> kept(String path) async {
    if (_waiting?.path == path) _flush();
    await _tail;
    return _unkept[path];
  }

  /// Whether the checkpoint of [path] on disk holds exactly the edits
  /// [draft] parks, written by this run: its offer can stand in for them.
  Future<bool> keeps(String path, RetainedDraft draft) async {
    final file = draft.shown.view?.file ?? draft.shown.chapter;
    if (!identical(_kept[path], file)) return false;
    return await kept(path) == null && identical(_kept[path], file);
  }

  /// The writes and the offer take turns, so a drop after a save cannot
  /// land before the checkpoint written just ahead of it and leave that
  /// checkpoint behind, and an offer reads what was written before it. A
  /// job that throws does not stop the ones after it.
  Future<void> _tail = Future.value();
  void _inTurn(Future<void> Function() job) => _tail = _tail
      .then((_) => job())
      .catchError((Object error) => log.w('keep unsaved viewer edits', error));

  Future<void> _keep(
    ({Chapter file, int game, Revision revision, String path}) waiting,
  ) async {
    try {
      final file = waiting.file;
      final text = file.lines.length < 200
          ? writeChapter(file)
          : await Isolate.run(() => writeChapter(file));
      await _drafts.keep(
        ViewerDraft(
          path: waiting.path,
          game: waiting.game,
          revision: waiting.revision,
          text: text,
        ),
      );
      _unkept.remove(waiting.path);
    } on Object catch (error) {
      // Derived from the draft on screen, which is still there: the next
      // edit tries again.
      log.w('keep unsaved viewer edits for ${waiting.path}', error);
      _unkept[waiting.path] =
          'Unsaved edits to ${p.basename(waiting.path)} were not kept: $error';
    }
  }

  Future<void> _drop(String path) async {
    _unkept.remove(path);
    try {
      await _drafts.drop(path);
    } on Object catch (error) {
      log.w('forget the unsaved viewer edits for $path', error);
    }
  }

  /// Offers the draft kept for [path], when the file shows one game at a
  /// time and nothing is held on it by now. A draft this run wrote is
  /// offered too: its tab may have been closed on it.
  Future<void> _offer(String path) async {
    final draft = await _drafts.find(path);
    if (_disposed || draft == null) return;
    if (_session.source?.path != path ||
        _session.hasHeldEdits ||
        _session.game == null) {
      return;
    }
    _offered = draft;
    final name = _session.source!.name;
    final earlier = _kept.containsKey(path) ? '' : ' from an earlier session';
    if (draft.revision == _saver.revision) {
      say(
        'Unsaved edits to $name$earlier.',
        action: (label: 'Restore unsaved edits', onPressed: restore),
        problem: false,
      );
    } else {
      // Restored over the file, they would undo whatever changed it since.
      say(
        'Unsaved edits to $name$earlier. The file has changed since.',
        action: (label: 'Save them as a copy', onPressed: saveCopy),
        problem: false,
      );
    }
  }

  /// Puts the offered edits back on the board as held edits.
  Future<void> restore() async {
    final draft = _offered;
    final source = _session.source;
    final shown = _session.chapter;
    if (draft == null || source == null || shown == null) return;
    if (source.path != draft.path || _session.hasHeldEdits) return;
    if (draft.revision != _saver.revision) return;
    final file = await readChapter(name: source.fileName, text: draft.text);
    if (_disposed || _offered != draft || _session.chapter != shown) return;
    if (file.lines.isEmpty) return;
    final restored = withGame(
      file,
      draft.game < file.lines.length ? draft.game : 0,
    );
    _withdraw();
    // These edits are the checkpoint: it is theirs to replace.
    _owns = true;
    _session.restoreDraft(
      RetainedDraft(
        shown: (chapter: restored, view: null),
        held: HeldEdits(
          (chapter: shown, view: null),
          (
            text: draft.text,
            scope: const WholeDocument(),
            chapter: restored,
            view: null,
          ),
        ),
        revision: draft.revision,
      ),
    );
  }

  /// Writes the offered edits beside their file under a name of their own,
  /// then forgets the checkpoint: the copy holds them now.
  Future<void> saveCopy() async {
    final draft = _offered;
    final source = _session.source;
    if (draft == null || source == null || source.path != draft.path) return;
    final file = await readChapter(name: source.fileName, text: draft.text);
    if (_disposed || _offered != draft) return;
    final base = '${p.basenameWithoutExtension(draft.path)} unsaved edits';
    var result = await _saver.copyAside(file, beside: source, name: base);
    for (var n = 2; result is CopyNameTaken && n <= 20; n++) {
      result = await _saver.copyAside(file, beside: source, name: '$base $n');
    }
    if (_disposed) return;
    switch (result) {
      case CopySaved(:final name):
        // Edits made meanwhile have set the checkpoint aside and own the
        // one on disk now.
        if (_offered == draft) {
          _offered = null;
          _kept.remove(draft.path);
          _inTurn(() => _drop(draft.path));
        }
        say('Saved the unsaved edits as $name', problem: false);
      case CopyNameTaken():
        say('Could not save the edits as a copy: every name was taken.');
      case CopyFailed(:final detail):
        say('Could not save the edits as a copy: $detail');
    }
  }

  /// A checkpoint the user edited past instead of restoring is moved aside
  /// whole, not written over: it may hold work nothing else has.
  void _setAside(String path) {
    _inTurn(() async {
      try {
        await _drafts.setAside(path);
      } on Object catch (error) {
        log.w('set aside the unsaved viewer edits for $path', error);
      }
    });
  }

  void _withdraw() {
    if (_offered == null) return;
    _offered = null;
    say(null);
  }

  /// Writes what is waiting on the way down: the window may be closing.
  void dispose() {
    _flush();
    _disposed = true;
    _session.removeListener(_changed);
    _saver.removeListener(_changed);
  }
}
