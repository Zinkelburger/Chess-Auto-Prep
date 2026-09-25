import 'package:path/path.dart' as p;

import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/reference_change.dart';
import '../../workspace/books.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'library_state.dart';

/// Accepted file changes retain their original identity and revision, including
/// when the native move landed but its acknowledgement did not. Every attempt
/// owns the same admission path, whether invoked by the UI or shutdown retry.
final class AcceptedFileChanges {
  AcceptedFileChanges({
    required this.documents,
    required this.saver,
    required this.session,
    required this.synchronize,
    required this.runRetry,
    this.books,
    this.pendingWrites,
  });

  final store.PgnDocumentStore documents;
  final DocumentSaver saver;
  final DocumentSession session;
  final Books? books;
  final PendingWrites? pendingWrites;
  final Future<void> Function() synchronize;
  final Future<LibraryResult> Function(Future<LibraryResult> Function())
  runRetry;
  final _commands = <(String, String?), _AcceptedFileChange>{};

  Future<LibraryResult> move(ChapterRef from, DocumentRef to) {
    final key = (from.path, to.path);
    final command = _commands.putIfAbsent(
      key,
      () => _AcceptedFileChange(this, from, to),
    );
    return command.run();
  }

  _AcceptedFileChange _deletion(ChapterRef from) => _commands.putIfAbsent((
    from.path,
    null,
  ), () => _AcceptedFileChange(this, from, null));
  Future<LibraryResult> delete(ChapterRef from) => _deletion(from).run();

  final _batches = <String, _DeleteRepertoire>{};
  Future<LibraryResult> deleteRepertoire(
    RepertoireFolder folder,
    Future<void> Function() removeEmpty,
  ) => _batches
      .putIfAbsent(
        folder.path,
        () => _DeleteRepertoire(this, folder, removeEmpty),
      )
      .run();
}

/// One command's captured inputs and uncertain outcome outlive its first UI
/// call. A successful receipt ends this obligation without replaying the change.
final class _AcceptedFileChange {
  factory _AcceptedFileChange(
    AcceptedFileChanges owner,
    ChapterRef from,
    DocumentRef? to,
  ) {
    final id = newCompoundId();
    return _AcceptedFileChange._(
      owner,
      from,
      to ??
          DocumentRef(
            p.join(
              p.dirname(from.path),
              '.cap-pgn-history',
              '$id-${p.basename(from.path)}',
            ),
          ),
      id,
      to == null,
    );
  }

  _AcceptedFileChange._(
    this.owner,
    this.from,
    this.to,
    this.id,
    this.deleting,
  ) {
    _obligation = owner.pendingWrites?.accept<LibraryResult>(
      resource: owner.documents,
      label: '${deleting ? 'Delete' : 'Move'} ${from.name}',
      work: _coordinated,
      problem: (result) => result is LibraryFailure ? result.detail : null,
      blocked: () =>
          const LibraryFailure('An earlier document change needs recovery.'),
    );
  }

  final AcceptedFileChanges owner;
  final ChapterRef from;
  final DocumentRef to;
  final String id;
  final bool deleting;
  Revision? _expected;
  bool _uncertain = false;
  PendingObligation<LibraryResult>? _obligation;

  Future<LibraryResult> run() async {
    final result = _obligation == null
        ? await _coordinated()
        : await _obligation!.run();
    if (result is LibraryFailure) {
      return LibraryFailure(result.detail, retry: () => owner.runRetry(run));
    }
    _resolved();
    return result;
  }

  void _resolved() {
    final key = (from.path, deleting ? null : to.path);
    if (identical(owner._commands[key], this)) owner._commands.remove(key);
  }

  Future<LibraryResult> _publish(Revision revision) async {
    _expected ??= revision;
    Future<LibraryResult> write() async => deleting
        ? _deleted(
            await owner.documents.delete(
              from,
              expected: _expected!,
              operationId: id,
            ),
            revision,
          )
        : _moved(
            await owner.documents.move(
              from,
              to,
              expected: _expected!,
              operationId: id,
            ),
            revision,
          );
    final books = owner.books;
    final result = books == null
        ? await write()
        : await books.changeReferences(write, failed: LibraryFailure.new);
    if (result is LibraryFailure) _uncertain = true;
    return result;
  }

  // Historical receipts may never bind or close a replacement editor opened
  // at the original path. Revision equality alone only compares content.
  bool _ownsEditor(Revision revision) =>
      revision == _expected &&
      revision.nativeIdentity == _expected!.nativeIdentity &&
      owner.session.source?.path == from.path;

  LibraryResult _moved(store.MoveResult result, Revision revision) {
    switch (result) {
      case store.Moved(:final training):
        if (_ownsEditor(revision)) {
          owner.session.relocated(ChapterRef.at(to.path));
        }
        return LibraryDone(training: training);
      case store.IoFailure(:final detail):
        return LibraryFailure(detail);
      case store.Conflict():
        return _conflict();
      case store.Collision():
        return _uncertain ? _unverified : const LibraryNameTaken();
    }
  }

  LibraryResult _deleted(store.DeleteResult result, Revision revision) {
    switch (result) {
      case store.Deleted(:final training):
        if (_ownsEditor(revision)) owner.session.closed();
        return LibraryDone(training: training);
      case store.IoFailure(:final detail):
        return LibraryFailure(detail);
      case store.Conflict():
        return _conflict();
    }
  }

  static const _unverified = LibraryFailure(
    'The pending file change could not be verified. Its original command is retained.',
  );
  LibraryResult _conflict() => _uncertain
      ? _unverified
      : owner.session.source?.path == from.path
      ? const LibraryConflicted()
      : const LibraryStale();

  Future<LibraryResult> _held() async {
    final result = await owner.saver.holdStill(_publish);
    if (result != null) return result;
    if (_expected == null && !_uncertain && owner.saver.settled) {
      return const LibraryBusy();
    }
    return const LibraryFailure(
      'Save or recover the open draft before changing its file.',
    );
  }

  Future<LibraryResult> _attempt() async {
    final guard = owner.saver.writeGuard?.call();
    try {
      final problem = await guard?.pauseForWrite();
      if (problem != null) return LibraryFailure(problem);
      if (owner.session.source?.path == from.path) return await _held();
      if (_expected case final revision?) return await _publish(revision);
      switch (await owner.documents.open(from)) {
        case store.Opened(:final revision):
          // Navigation started before admission may finish while reading.
          return owner.session.source?.path == from.path
              ? await _held()
              : await _publish(revision);
        case store.Absent():
          return const LibraryStale();
        case store.Unreadable(:final detail):
          return LibraryFailure(detail);
      }
    } finally {
      try {
        await owner.synchronize();
      } finally {
        guard?.resumeAfterWrite();
      }
    }
  }

  Future<LibraryResult> _coordinated() async {
    try {
      // Register both names before the first await: neither old nor new
      // navigation may observe the interval spent draining accepted books.
      final result = await owner.session.access.changing(
        from.path,
        () => from.path == to.path
            ? _attempt()
            : owner.session.access.changing(to.path, _attempt),
      );
      // Registry retries execute this coordinator directly, without run().
      if (result is! LibraryFailure) _resolved();
      return result;
    } on Object catch (error) {
      _uncertain = true;
      return LibraryFailure('The file change needs recovery: $error');
    }
  }
}

/// A stopped batch keeps its current accepted command even if registry retry
/// has already completed that file. Earlier files are never deleted twice.
final class _DeleteRepertoire {
  _DeleteRepertoire(this.owner, this.folder, this.removeEmpty)
    : remaining = {
        for (final chapter in folder.chapters) chapter.path: chapter.wholeFile,
      }.values.toList();
  final AcceptedFileChanges owner;
  final RepertoireFolder folder;
  final Future<void> Function() removeEmpty;
  final List<ChapterRef> remaining;
  final _results = <LibraryDone>[];
  int _next = 0;
  _AcceptedFileChange? _active;
  LibraryDone? _completed;

  Future<LibraryResult> run() async {
    if (_completed case final result?) return result;
    while (_next < remaining.length) {
      final file = remaining[_next];
      final result = await (_active ??= owner._deletion(file)).run();
      if (result is LibraryDone) {
        _results.add(result);
        _active = null;
        _next++;
        continue;
      }
      // A confirmed refusal carries no unresolved write. A fresh invocation
      // can read that file again; uncertain failures retain the exact command.
      if (result is! LibraryFailure) _active = null;
      return LibraryStoppedAt(
        file.name,
        result is LibraryFailure
            ? LibraryFailure(result.detail, retry: () => owner.runRetry(run))
            : result,
      );
    }
    await removeEmpty();
    if (identical(owner._batches[folder.path], this)) {
      owner._batches.remove(folder.path);
    }
    return _completed = LibraryDone(
      training: foldedRepoint([for (final result in _results) result.training]),
    );
  }
}
