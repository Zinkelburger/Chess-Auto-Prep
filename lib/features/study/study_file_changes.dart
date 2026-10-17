import 'package:path/path.dart' as p;

import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/deleted_chapters.dart';
import '../../storage/document_ref.dart';
import '../../storage/operation_id.dart';
import '../../storage/pending_writes.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/player_files.dart';
import '../../storage/relocation_notes.dart' show recoveryFolder;
import '../../ui/file_names.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'studies_state.dart';

/// How a study file is renamed, restored from recovery or deleted on disk,
/// and how the workspace follows it.
///
/// Each change reads the revision it acts on when it runs, holding the file
/// against opening while it does ([changing]). A rename or restore the store
/// could not confirm keeps its operation id and the revision it read until a
/// retry settles it ([canRetryRename], [canRetryRestore]). A study that
/// Players & prep links to is neither renamed nor deleted.
final class StudyFileChanges {
  StudyFileChanges({
    required this._store,
    required this._session,
    required this._saver,
    required this._root,
    required this._resource,
    this.pendingWrites,
    this.linkedPlayers,
  });

  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final DocumentSaver _saver;

  /// The `studies` folder, absolute.
  final String _root;

  /// What the moves are accepted as owed by: the owner whose one change at a
  /// time they are, which its own saves share.
  final Object _resource;
  final PendingWrites? pendingWrites;
  final PlayerStore? linkedPlayers;

  /// A rename changes the file's name, preserving all PGN bytes and tags.
  /// The original revision and operation id survive an uncertain result.
  _StudyRename? _rename;
  bool get canRetryRename => _rename != null;

  /// Whether the rename waiting for a retry is of [from] to [to].
  bool renames(ChapterRef from, ChapterRef to) =>
      _rename?.from == from && _rename?.to == to;

  /// [study] renamed to [to], unless Players & prep links to it.
  Future<StudyResult> rename(ChapterRef study, ChapterRef to) async {
    final linkProblem = await _linked(study, doing: 'renaming');
    if (linkProblem != null) return StudyProblem(linkProblem);
    return _session.access.changing(
      study.path,
      () => _session.access.changing(
        to.path,
        () => _withRevision(study, (revision) async {
          final id = newOperationId();
          final token = Object();
          if (_session.source == study &&
              !_saver.beginExternal(token, revision)) {
            return studyChangedOnDisk;
          }
          final pending = pendingWrites ?? PendingWrites();
          Future<store.MoveResult> work() =>
              _store.move(study, to, expected: revision, operationId: id);
          final obligation = pending.accept<store.MoveResult>(
            resource: _resource,
            label: 'Rename study',
            work: work,
            // One the store recorded is finished by recovery, so exit
            // does not ask about it.
            problem: (result) =>
                result is store.IoFailure && result is! store.Unfinished
                ? result.detail
                : null,
          );
          _rename = _StudyRename(
            study,
            to,
            token,
            obligation,
            () => pending.track(_resource, work(), label: 'Rename study'),
          );
          return _finishRename();
        }),
      ),
    );
  }

  /// Why [study] cannot be moved from its path — players or groups in
  /// Players & prep name it there — or null when nothing does. [doing] is
  /// the change being asked for, for the sentence.
  Future<String?> _linked(ChapterRef study, {required String doing}) async {
    final source = linkedPlayers;
    if (source == null) return null;
    try {
      final data = await source.read();
      if (data.warnings.isNotEmpty) {
        return 'The player directory needs attention before $doing a linked study.';
      }
      final names = [
        for (final player in data.players)
          if (p.equals(player.text('prep_file'), study.path)) player.name,
        for (final group in data.groups)
          if (group.fields['study'] == study.path) group.name,
      ];
      return names.isEmpty
          ? null
          : 'This study is linked to ${names.join(', ')} in Players & prep. Update its links before $doing it.';
    } on Object catch (error) {
      log.w('check study links', error);
      return 'Could not check study links. Retry when the player directory is readable.';
    }
  }

  Future<StudyResult> retryRename() async {
    final move = _rename;
    if (move == null) return const StudyDone();
    return _session.access.changing(
      move.from.path,
      () => _session.access.changing(
        move.to.path,
        () async => _session.source == move.from
            ? await _saver.holdStill(
                    (_) => _finishRename(),
                    continuing: move.token,
                  ) ??
                  studyChangedOnDisk
            : _finishRename(),
      ),
    );
  }

  Future<StudyResult> _finishRename() async {
    final move = _rename!;
    // A recorded rename left the obligations when the store answered
    // Unfinished; asking again under its id follows it to where recovery
    // carried it, and a refusal while it is still owed stays unasked at exit.
    final result = move.pending.committed
        ? await move.again()
        : await move.pending.run();
    if (result is! store.IoFailure) _rename = null;
    switch (result) {
      case store.Moved():
        if (_session.source == move.from) _session.relocated(move.to);
        _saver.resolveExternalMove(move.token);
        return const StudyDone();
      case store.Collision():
        _saver.resolveExternalMove(move.token);
        return const StudyProblem('A study with that name already exists.');
      case store.Conflict():
        _saver.resolveExternalMove(
          move.token,
          failure: studyChangedOnDisk.sentence,
        );
        return studyChangedOnDisk;
      case store.IoFailure(:final detail):
        // Edits wait until the study follows its rename: recovery may move
        // the file at any access, recorded or not.
        _saver.resolveExternalMove(
          move.token,
          failure: detail,
          uncertain: true,
        );
        return StudyProblem(
          'Rename was not confirmed: $detail. Retry rename to finish.',
        );
    }
  }

  _StudyRename? _restore;
  bool get canRetryRestore => _restore != null;
  Future<StudyResult> restore(DeletedChapter deleted, {String? name}) async {
    final wanted = name ?? deleted.name;
    if (nameProblem(wanted) case final wrong?) return StudyProblem(wrong);
    if (!p.equals(deleted.folder, _root) ||
        !p.equals(p.dirname(deleted.path), p.join(_root, recoveryFolder))) {
      return const StudyProblem(
        'That deleted study is outside the studies folder.',
      );
    }
    final from = ChapterRef.at(deleted.path);
    final to = ChapterRef.at(p.join(_root, '$wanted.pgn'));
    if (_restore case final existing?) {
      if (existing.from != from || existing.to != to) {
        return const StudyProblem('Retry the pending study restore first.');
      }
      return retryRestore();
    }
    return changing(
      from.path,
      () => changing(to.path, () async {
        final read = await _store.open(from);
        if (read is! store.Opened) {
          return const StudyProblem(
            'That deleted study could not be read. Refresh and try again.',
          );
        }
        if (read.readOnly case final reason?) return StudyProblem(reason);
        final id = newOperationId();
        final pending = pendingWrites ?? PendingWrites();
        Future<store.MoveResult> work() =>
            _store.move(from, to, expected: read.revision, operationId: id);
        _restore = _StudyRename(
          from,
          to,
          Object(),
          pending.accept<store.MoveResult>(
            resource: _resource,
            label: 'Restore study',
            work: work,
            problem: (result) =>
                result is store.IoFailure && result is! store.Unfinished
                ? result.detail
                : null,
          ),
          () => pending.track(_resource, work(), label: 'Restore study'),
        );
        return _finishRestore();
      }),
    );
  }

  Future<StudyResult> retryRestore() async {
    final move = _restore;
    if (move == null) return const StudyDone();
    return changing(
      move.from.path,
      () => changing(move.to.path, _finishRestore),
    );
  }

  Future<StudyResult> _finishRestore() async {
    final move = _restore!;
    final result = move.pending.committed
        ? await move.again()
        : await move.pending.run();
    if (result is! store.IoFailure) _restore = null;
    return switch (result) {
      store.Moved() => const StudyDone(),
      store.Collision() => const StudyProblem(
        'A study with that name already exists. Use Restore as to choose another name.',
      ),
      store.Conflict() => const StudyProblem(
        'The deleted study changed. Refresh and try again.',
      ),
      store.IoFailure(:final detail) => StudyProblem(
        'Restore was not confirmed: $detail. Retry restore to finish.',
      ),
    };
  }

  /// Recoverable: the file goes to the recovery folder through the store,
  /// which is where a deleted chapter goes too. A study Players & prep
  /// links to stays, as it does for a rename.
  Future<StudyResult> delete(ChapterRef study) async {
    final linkProblem = await _linked(study, doing: 'deleting');
    if (linkProblem != null) return StudyProblem(linkProblem);
    return changing(
      study.path,
      () => _withRevision(study, (revision) async {
        switch (await _store.delete(study, expected: revision)) {
          case store.Deleted():
            if (_session.source == study) _session.closed();
            return const StudyDone();
          case store.Conflict():
            return const StudyProblem(
              'That study changed on disk while it was open. Reload it, '
              'then try again.',
            );
          case store.IoFailure(:final detail):
            return StudyProblem('Could not delete the study: $detail');
        }
      }),
    );
  }

  /// Runs [work] with opening [path] held off until it is over. Another
  /// command already changing that file is a refusal, not a wait.
  Future<StudyResult> changing(
    String path,
    Future<StudyResult> Function() work,
  ) async {
    try {
      return await _session.access.changing(path, work);
    } on StateError catch (error) {
      log.w('change $path', error);
      return const StudyProblem('Another change is still running.');
    }
  }

  /// Runs [write] against the revision [study] has now.
  ///
  /// The study open in the workspace is held still by its saver until
  /// [write] is over, so an autosave cannot land between the revision and
  /// the write that expects it. Any other is read from disk, which is also
  /// the check that it is still there.
  Future<StudyResult> _withRevision(
    ChapterRef study,
    Future<StudyResult> Function(Revision revision) write,
  ) async {
    if (_session.source == study) return _held(write);
    switch (await _store.open(study)) {
      case store.Opened(:final revision):
        // The user may have opened the study while it was being read, and
        // from here on its writes belong behind the saver's hold.
        if (_session.source == study) return _held(write);
        return write(revision);
      case store.Absent():
        return studyChangedOnDisk;
      case store.Unreadable(:final detail):
        log.w('read ${study.path} before changing it', detail);
        return studyChangedOnDisk;
    }
  }

  /// Runs [write] with the open study held still by its saver. When the
  /// saver cannot hold it — nothing is open by the time its draft is
  /// written, or another change holds it — the answer is the one for a
  /// study gone from disk: the list is read again and the user tries again.
  Future<StudyResult> _held(
    Future<StudyResult> Function(Revision revision) write,
  ) async => await _saver.holdStill(write) ?? studyChangedOnDisk;
}

final class _StudyRename {
  const _StudyRename(this.from, this.to, this.token, this.pending, this.again);
  final Object token;
  final ChapterRef from, to;
  final PendingObligation<store.MoveResult> pending;

  /// The same move under the same operation id, waited for at exit but not
  /// asked about: for a rename the store recorded.
  final Future<store.MoveResult> Function() again;
}
