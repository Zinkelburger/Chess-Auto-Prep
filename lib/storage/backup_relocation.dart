import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backups.dart';
import 'journal_records.dart';
import 'operation_id.dart';
import 'operation_journal.dart';
import 'recovery_files.dart';

/// Which kept-version folder follows a document when it moves, recorded in
/// the move's journal so a restarted move carries the history the same way.
///
/// Kept versions follow a document, but they never decide whether it may
/// move ([KeptVersions]): a history the disk refuses for now keeps the move
/// recorded and is tried again; one that cannot move for another reason
/// stays under its old id, whole and readable, the move still completes, and
/// the history move stays owed (`Support/backup-moves/`) until a later
/// recovery finishes it.
final class BackupMove {
  BackupMove({
    required this.operationId,
    required this.rootPath,
    required this.fromId,
    required this.toId,
    required this.documentPath,
  }) {
    OperationId(operationId);
    if (_id.stringMatch(fromId) != fromId ||
        _id.stringMatch(toId) != toId ||
        fromId == toId ||
        !_absolute(rootPath) ||
        !_absolute(documentPath)) {
      throw const RecoveryRequired('Invalid backup ownership plan.');
    }
  }

  /// Reads both this format and the earlier one, which also listed every kept
  /// file with its hash; that inventory is no longer needed and is ignored.
  factory BackupMove.fromJson(Map<String, Object?> json) {
    String text(String key) => switch (json[key]) {
      final String value => value,
      _ => throw const RecoveryRequired('Invalid backup ownership plan.'),
    };
    return BackupMove(
      operationId: text('operationId'),
      rootPath: text('rootPath'),
      fromId: text('fromId'),
      toId: text('toId'),
      documentPath: text('documentPath'),
    );
  }

  final String operationId;
  final String rootPath;
  final String fromId;
  final String toId;
  final String documentPath;

  Map<String, Object?> toJson() => {
    'version': 2,
    'operationId': operationId,
    'rootPath': rootPath,
    'fromId': fromId,
    'toId': toId,
    'documentPath': documentPath,
  };
}

/// Moves a document's kept versions to its new id. Every step checks what is
/// already on disk, so running it again after a stop finishes the move.
/// [move], [synchronize] and [windows] stand in for the platform in tests.
final class BackupRelocation {
  BackupRelocation(
    this.root, {
    required this.documents,
    Future<void> Function(String from, String to) move = movePathNoReplace,
    Future<void> Function(String) synchronize = syncDirectory,
    bool? windows,
  }) : _move = move,
       _synchronize = synchronize,
       _windows = windows ?? Platform.isWindows;

  final Directory root;

  /// The Documents folder, where a history displaced by a move is offered
  /// back as a deleted chapter.
  final Directory documents;

  final Future<void> Function(String from, String to) _move;
  final Future<void> Function(String) _synchronize;
  final bool _windows;

  /// Whether nothing is left to move. Never throws: a failure is logged and
  /// leaves the history where it is ([carry] says what stopped it).
  Future<bool> applyMove(
    BackupMove move, {
    DateTime? retryUntil,
    bool merge = false,
  }) async {
    try {
      await carry(move, retryUntil: retryUntil, merge: merge);
      return true;
    } on Object catch (error) {
      log.w('move the kept versions of ${move.documentPath}', error);
      return false;
    }
  }

  /// Moves the history, throwing what stopped it; the history is left where
  /// it was, whole and readable.
  ///
  /// On Windows a folder does not rename while antivirus or the indexer holds
  /// a file in it, as it may the version a delete has just kept. Every step
  /// looks at the disk first, so the whole move is tried again until
  /// [retryUntil] (two seconds from now when not given); callers moving
  /// several histories share one deadline so a lasting refusal costs it once.
  ///
  /// [merge] says a history already at the new id is the document's own,
  /// kept since it moved while this one was owed, so the two are merged
  /// rather than the newer one displaced as another document's.
  Future<void> carry(
    BackupMove move, {
    DateTime? retryUntil,
    bool merge = false,
  }) async {
    final deadline =
        retryUntil ?? DateTime.now().add(const Duration(seconds: 2));
    while (true) {
      try {
        return await _carry(move, merge: merge);
      } on FileSystemException catch (error) {
        if (!_windows ||
            !const [5, 32, 33].contains(error.osError?.errorCode) ||
            !DateTime.now().isBefore(deadline)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _carry(BackupMove move, {required bool merge}) async {
    final from = p.join(move.rootPath, move.fromId);
    final to = p.join(move.rootPath, move.toId);
    if (await _exists(from)) {
      if (await _exists(to)) {
        if (merge) {
          await BackupArchive(root).merge(
            fromId: move.fromId,
            toId: move.toId,
            documentPath: move.documentPath,
            operationId: move.operationId,
            move: _move,
          );
        } else {
          await _displace(to, move);
        }
      }
      if (!await _exists(to)) await _move(from, to);
    }
    if (await _exists(to)) {
      // The caller forgets the move next, so the renames made here, or by a
      // run a crash stopped, must be on disk first.
      await flushRecoveryDirectory(move.rootPath, synchronize: _synchronize);
      await _repointIndex(to, move.documentPath);
    }
  }

  /// A history already under the target id belongs to a document that used to
  /// have that path and was renamed or removed by another program. Braiding
  /// the two would offer one document's text as a version of the other, so it
  /// moves out whole: its newest version goes to the deleted chapters of the
  /// folder the document lived in, and its history goes with it, so it can be
  /// restored from there like any deleted chapter.
  Future<void> _displace(String occupant, BackupMove move) async {
    final newest = await BackupArchive(root).newest(p.basename(occupant));
    final folder = p.dirname(move.documentPath);
    if (newest == null) {
      final aside = '$occupant.superseded-${move.operationId}';
      await _move(occupant, aside);
      log.w('set aside unreadable kept versions at $aside');
      return;
    }
    final stamp = newest.version.time.microsecondsSinceEpoch;
    final token = newest.version.hash.substring(0, 8);
    final name = '$stamp-$token-${p.basename(move.documentPath)}';
    final chapter = p.join(folder, '.cap-pgn-history', name);
    if (!await File(chapter).exists()) {
      // The chapter's own flush does not persist a new history folder, and
      // the occupant moves out of Support only once the chapter is kept.
      final history = Directory(p.dirname(chapter));
      final boundary = recoveryMetadataBoundary(history);
      await history.create(recursive: true);
      await flushRecoveryAncestry(
        history.parent.path,
        through: boundary,
        synchronize: _synchronize,
      );
      await createFileExclusively(chapter, newest.bytes);
    }
    final id = backupId(p.relative(chapter, from: documents.path));
    await _move(occupant, p.join(move.rootPath, id));
    await _repointIndex(p.join(move.rootPath, id), chapter);
    log.w('offered the kept versions displaced from $occupant as $chapter');
  }

  Future<void> _repointIndex(String folder, String documentPath) async {
    final index = File(p.join(folder, 'index.json'));
    if (!await index.exists()) return;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(await index.readAsBytes()));
    } on FormatException {
      return; // The archive rebuilds an index it cannot read.
    }
    if (json is! Map<String, Object?> || json['path'] == documentPath) return;
    await replaceFile(
      index.path,
      utf8.encode(jsonEncode({...json, 'path': documentPath})),
    );
  }
}

Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) ==
    FileSystemEntityType.directory;

bool _absolute(String value) =>
    !value.contains('\u0000') &&
    p.isAbsolute(value) &&
    p.normalize(value) == value;
final _id = RegExp(r'^[0-9a-f]{16}$');

/// A move's kept versions, which follow its documents to their new ids.
/// Kept versions never decide whether a document moves. A history the disk
/// refuses for now (held open, no permission for the moment) keeps the move
/// recorded, so it is tried again soon; one that cannot move for another
/// reason stays whole under its old id and is owed ([OwedHistories]).
///
/// Once the move stopped guarding its documents ([following]), saves may
/// have kept versions under the new ids. The histories were owed at the
/// handover, before they could, and [OwedHistories] alone carries them from
/// then on: owed again after it had merged one, the document's own history
/// would read as another document's.
final class KeptVersions implements Reference {
  KeptVersions(
    this.moves, {
    required this.root,
    required this.documents,
    required this.owed,
    this.following = false,
    this.moved,
  });

  final Iterable<BackupMove> moves;

  /// The folder of kept versions, `Support/backups`.
  final Directory root;
  final Directory documents;
  final OwedHistories owed;
  final bool following;

  /// Told after each history is moved or owed, or left to [owed].
  final Future<void> Function()? moved;

  @override
  Future<Holds> look() async => const HoldsBefore();

  @override
  Future<void> follow() async {
    final relocation = BackupRelocation(root, documents: documents);
    final retryUntil = DateTime.now().add(const Duration(seconds: 2));
    for (final move in moves) {
      if (!following) {
        try {
          await relocation.carry(move, retryUntil: retryUntil);
        } on FileSystemException {
          rethrow;
        } on Object catch (error) {
          log.w('move the kept versions of ${move.documentPath}', error);
          await owed.owe(move);
        }
      }
      await moved?.call();
    }
  }
}

/// The histories a move could not carry, written down in
/// `Support/backup-moves/<from>-<to>.json` so a later recovery moves them
/// and a new document at the old path does not inherit them.
final class OwedHistories {
  OwedHistories({
    required this.support,
    required this.documents,
    this._synchronize = syncDirectory,
  });

  /// The canonical profile roots.
  final Directory support;
  final Directory documents;
  final Future<void> Function(String) _synchronize;

  Directory get _folder => Directory(p.join(support.path, 'backup-moves'));
  String get _root => p.join(support.path, 'backups');

  /// Writes down [move]; the document's own move is finished either way.
  /// False, and logged, when it could not be written down.
  ///
  /// It also notes whether the new id was free. If it was, whatever is kept
  /// there by then is the document's own, saved since it moved, and the
  /// owed history merges into it; otherwise the occupant is another
  /// document's, still to be displaced.
  Future<bool> owe(BackupMove move) async {
    final path = p.join(_folder.path, '${move.fromId}-${move.toId}.json');
    try {
      final free =
          await FileSystemEntity.type(
            p.join(move.rootPath, move.toId),
            followLinks: false,
          ) !=
          FileSystemEntityType.directory;
      await recoveryDirectory(_folder, create: true);
      await discardLeftoverStage(path);
      await createFileExclusively(
        path,
        encodeJournal({...move.toJson(), 'merge': free}),
      );
    } on NativeNameCollision {
      // Already owed: the same ids always name the same move.
    } on Object catch (error) {
      log.w('write down the kept versions still to move at $path', error);
      return false;
    }
    return true;
  }

  /// Moves the histories [owe] wrote down. One whose document has gone from
  /// where it was moved to is dropped, not moved: a later move, such as a
  /// restore, has already picked the history up where it is. This runs with
  /// each recovery pass rather than before every access, and tries each once
  /// without waiting, so a history that stays stuck never slows the app.
  Future<void> moveAll() async {
    final owed = await readJournal(
      _folder,
      decode: (value, id) {
        if (value is! Map<String, Object?>) {
          throw const RecoveryRequired('Invalid backup ownership plan.');
        }
        final move = BackupMove.fromJson(value);
        if (id != '${move.fromId}-${move.toId}' ||
            move.rootPath != _root ||
            !p.isWithin(documents.path, move.documentPath) ||
            move.toId !=
                backupId(p.relative(move.documentPath, from: documents.path))) {
          throw const RecoveryRequired('Backup ownership plan disagrees.');
        }
        return (move: move, merge: value['merge'] == true);
      },
    );
    final relocation = BackupRelocation(
      Directory(_root),
      documents: documents,
      synchronize: _synchronize,
    );
    for (final (file, (:move, :merge)) in owed) {
      try {
        final here =
            await FileSystemEntity.type(
              move.documentPath,
              followLinks: false,
            ) ==
            FileSystemEntityType.file;
        if (!here) {
          log.w(
            'dropped the kept versions owed to ${move.documentPath}, which '
            'has moved on; they stay under ${move.fromId}',
          );
        } else if (!await relocation.applyMove(
          move,
          retryUntil: DateTime.now(),
          merge: merge,
        )) {
          continue;
        }
        await forgetRecord(file, synchronize: _synchronize);
      } on Object catch (error) {
        log.w('move the kept versions recorded at ${file.path}', error);
      }
    }
  }
}
