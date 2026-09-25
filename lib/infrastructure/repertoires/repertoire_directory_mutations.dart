import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../../features/repertoires/models/repertoire_recovery_required.dart';
import '../../features/repertoires/models/repertoire_recovery_entry.dart';
import '../../utils/safe_file_name.dart';
import '../../services/storage/file_mutation_service.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_operation_lock.dart';
import 'foreign_relocation_history.dart';
import 'foreign_recovery_copies.dart';

enum RepertoireMoveStep { prepared, moved, referencesUpdated, completed }

/// Namespace move + replayable reference migration. A pending operation blocks
/// later managed operations until native identity proves its outcome. Receipts
/// are retained, including cancelled preparations; no history is auto-pruned.
class RepertoireDirectoryMutations {
  RepertoireDirectoryMutations({
    required this.root,
    required this.journals,
    required this.repoint,
    this.testHook,
    this.recoverAdditional,
    this.foreignRecoveryNotes,
    this.compoundRecoveryNotes,
    this.relocationRecoveryNotes,
    this.compoundDocumentsRoot,
    this.trash,
    this.trashAllowedRoot,
    FileMutationService? mutations,
  }) : _mutations = mutations ?? FileMutationService();

  static const stagingName = '.cap-repertoire-publications';
  final Future<void> Function()? recoverAdditional;
  final Directory root;
  final Directory journals;

  /// Existing v2 notes have no completed state: any entry requires v2 recovery.
  final Directory? foreignRecoveryNotes;

  /// Versioned v2 PGN/book operations. Terminal history remains compatible;
  /// pending or unrecognized metadata requires its owning application's recovery.
  final Directory? compoundRecoveryNotes;
  final Directory? relocationRecoveryNotes;
  final Directory? compoundDocumentsRoot;
  final Directory? trash;
  final Directory? trashAllowedRoot;
  final Future<void> Function(String from, String to, String operationId)
  repoint;
  final Future<void> Function(RepertoireMoveStep step)? testHook;
  final FileMutationService _mutations;

  /// Distinct from each file lock; the lock order is domain, namespace, file.
  Future<T> guard<T>(Future<T> Function() action) async {
    final canonicalRoot = await root.resolveSymbolicLinks();
    return withFileOperationLock(
      p.join(canonicalRoot, '.cap-directory-domain'),
      () async {
        await checkForeignRelocationHistory(
          relocationRecoveryNotes,
          documents: compoundDocumentsRoot,
        );
        await _refuseCompoundRecovery();
        await _refuseForeignRecovery();
        await _recover();
        await recoverAdditional?.call();
        return action();
      },
    );
  }

  Future<void> _refuseForeignRecovery() async {
    final notes = foreignRecoveryNotes;
    if (notes == null) return;
    try {
      final type = await FileSystemEntity.type(notes.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw const FormatException(
          'Unfinished move storage is not a directory',
        );
      }
      await for (final entry in notes.list(followLinks: false)) {
        // Unknown names, partial files and links are evidence too. Never follow
        // or remove them, and never mistake an unreadable note for no note.
        throw RepertoireRecoveryRequired(
          p.basename(entry.path),
          'Unfinished v2 move',
          message:
              'Reopen v2 to recover the unfinished move '
              '${p.basename(entry.path)} before accessing documents or training. '
              'Its recovery files have been preserved.',
        );
      }
    } on RepertoireRecoveryRequired {
      rethrow;
    } on Object catch (error) {
      throw RepertoireRecoveryRequired(
        notes.path,
        error,
        message:
            'The unfinished v2 moves could not be checked. Reopen v2 '
            'to resolve recovery before accessing documents or training. '
            'Its recovery files have been preserved.',
      );
    }
  }

  Future<void> _refuseCompoundRecovery() async {
    final notes = compoundRecoveryNotes;
    if (notes == null) return;
    try {
      final type = await FileSystemEntity.type(notes.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw const FormatException(
          'Compound write storage is not a directory',
        );
      }
      final documents = compoundDocumentsRoot;
      if (documents == null) {
        throw const FormatException(
          'Compound document boundary is unavailable',
        );
      }
      final roots = {p.normalize(p.absolute(documents.path))};
      if (await documents.exists()) {
        roots.add(p.normalize(await documents.resolveSymbolicLinks()));
      }
      await checkForeignRecoveryHistory(
        notes,
        validate: (value, id, terminal) {
          _checkCompoundHistory(value, id, roots, terminal: terminal);
        },
      );
    } on Object catch (error) {
      throw RepertoireRecoveryRequired(
        notes.path,
        error,
        message:
            'A compound document operation requires recovery. Reopen v2 '
            'to resolve it before accessing documents or training. '
            'Its recovery files have been preserved.',
      );
    }
  }

  void _checkCompoundHistory(
    Object? value,
    String id,
    Set<String> roots, {
    required bool terminal,
  }) {
    if (value is! Map<String, Object?> ||
        value.length != _compoundFields.length ||
        !value.keys.toSet().containsAll(_compoundFields) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['id'] != id ||
        !(terminal
                ? const {'complete', 'cancelled'}
                : const {'prepared', 'committing', 'complete', 'cancelled'})
            .contains(value['state']) ||
        value['documentBefore'] is! String ||
        value['documentAfter'] is! String ||
        (value['booksBefore'] != null && value['booksBefore'] is! String) ||
        (value['booksAfter'] != null && value['booksAfter'] is! String)) {
      throw FormatException('Pending or unknown compound operation: $id');
    }
    for (final field in [
      'documentBefore',
      'documentAfter',
      'booksBefore',
      'booksAfter',
    ]) {
      final text = value[field] as String?;
      if (text == null) continue;
      if (text.contains('\u0000') ||
          utf8.decode(utf8.encode(text)) != text ||
          (field.startsWith('books') &&
              jsonDecode(text) is! Map<String, Object?>)) {
        throw FormatException('Invalid compound snapshot: $id');
      }
    }
    final path = value['documentPath'];
    if (path is! String ||
        path.contains('\u0000') ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.pgn' ||
        !roots.any((root) => p.isWithin(root, path))) {
      throw FormatException('Invalid compound document path: $id');
    }
  }

  static const _compoundFields = {
    'version',
    'id',
    'state',
    'documentPath',
    'documentBefore',
    'documentAfter',
    'booksBefore',
    'booksAfter',
  };

  Future<void> recover() => guard(() async {});

  Future<void> move(String from, String to) => guard(() => _move(from, to));

  Future<void> delete(String path) => guard(() async {
    final recovery = trash;
    final allowed = trashAllowedRoot;
    if (recovery == null || allowed == null) {
      throw UnsupportedError('Recovery storage is not configured');
    }
    await _mutations.validateManagedDirectoryPath(
      recovery,
      allowedRoot: allowed,
    );
    await recovery.create(recursive: true);
    await _mutations.validateManagedDirectoryPath(
      recovery,
      allowedRoot: allowed,
    );
    // Persist newly created recovery ancestors before recording a move into
    // them. The source and destination parents are also flushed after rename.
    var ancestor = recovery;
    final boundary = p.normalize(p.absolute(allowed.path));
    while (true) {
      await syncDirectory(ancestor.path);
      if (p.equals(p.normalize(p.absolute(ancestor.path)), boundary)) break;
      ancestor = ancestor.parent;
    }
    final id = _newId();
    await _move(path, p.join(recovery.path, id), kind: 'trash', id: id);
  });

  Future<List<RepertoireRecoveryEntry>> listRecovery() => guard(() async {
    final records = await _records();
    final restored = records
        .where((r) => r.kind == 'restore' && r.state == 'completed')
        .map((r) => r.recoveryId)
        .toSet();
    final result = <RepertoireRecoveryEntry>[];
    for (final record in records.reversed) {
      if (record.kind != 'trash' ||
          record.state != 'completed' ||
          restored.contains(record.id)) {
        continue;
      }
      await _validateOperation(record, history: true);
      final observation = await observeDirectory(record.to);
      result.add(
        RepertoireRecoveryEntry(
          id: record.id,
          name: p.basename(record.from),
          originalPath: record.from,
          deletedAt: DateTime.fromMicrosecondsSinceEpoch(
            int.parse(record.id.split('-').first),
          ),
          available:
              observation.status == 0 &&
              observation.identity == record.identity,
        ),
      );
    }
    return result;
  });

  Future<void> restore(String id, {String? name}) => guard(() async {
    final records = await _records();
    final candidates = records.where(
      (r) => r.id == id && r.kind == 'trash' && r.state == 'completed',
    );
    if (candidates.length != 1 ||
        records.any(
          (r) =>
              r.kind == 'restore' &&
              r.recoveryId == id &&
              r.state == 'completed',
        )) {
      throw StateError('This recovery entry is no longer available.');
    }
    final original = candidates.single;
    await _validateOperation(original, history: true);
    if ((await observeDirectory(original.to)).identity != original.identity) {
      throw StateError(
        'Recovery files changed; the retained receipt cannot authorize restore.',
      );
    }
    final target = name == null
        ? original.from
        : p.join(p.dirname(original.from), requireSafeFileName(name));
    await _move(
      original.to,
      target,
      kind: 'restore',
      recoveryId: id,
      expectedIdentity: original.identity,
    );
  });

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

  Future<void> _move(
    String from,
    String to, {
    String kind = 'move',
    String? id,
    String? recoveryId,
    String? expectedIdentity,
  }) async {
    if (p.equals(p.normalize(from), p.normalize(to))) return;
    final source = Directory(p.normalize(p.absolute(from)));
    final destination = Directory(p.normalize(p.absolute(to)));
    await _validate(source.path, destination.path, kind);
    final observation = await observeDirectory(source.path);
    if (observation.status != 0 ||
        observation.identity == null ||
        (expectedIdentity != null &&
            observation.identity != expectedIdentity)) {
      throw FileSystemException(
        'Cannot verify source directory identity',
        from,
      );
    }
    id ??= _newId();
    final operation = _Move(
      id,
      source.path,
      destination.path,
      observation.identity!,
      'pending',
      kind: kind,
      recoveryId: recoveryId,
    );
    var prepared = false;
    try {
      await _mutations.moveDirectoryNoReplace(
        source,
        destination,
        allowedRoot: kind == 'restore' ? trash! : root,
        destinationAllowedRoot: kind == 'trash' ? trash! : root,
        installNoReplace: () =>
            movePathNoReplace(source.path, destination.path),
        beforeMove: () async {
          if ((await observeDirectory(source.path)).identity !=
              operation.identity) {
            throw FileSystemException('Source changed before rename', from);
          }
          prepared = true;
          await _write(operation, create: true);
          await testHook?.call(RepertoireMoveStep.prepared);
        },
        afterMove: () async {
          await testHook?.call(RepertoireMoveStep.moved);
        },
      );
      await _finish(operation);
    } on NativeNameCollision {
      await _write(operation.withState('cancelled'));
      throw FileSystemException(
        'Destination already exists; refusing to replace it',
        to,
      );
    } catch (error) {
      if (prepared) throw RepertoireRecoveryRequired(id, error);
      rethrow;
    }
  }

  Future<void> _validate(String from, String to, String kind) async {
    final privateRoot = p.join(root.path, stagingName);
    if ([from, to].any(
      (path) => p.equals(path, privateRoot) || p.isWithin(privateRoot, path),
    )) {
      throw const UnsafeFileMutation(
        'Publication staging is not a repertoire.',
      );
    }
    if (p.equals(from, to) || p.isWithin(from, to)) {
      throw const UnsafeFileMutation('A directory cannot move into itself.');
    }
    await _mutations.validateManagedDirectoryPath(
      Directory(from),
      allowedRoot: kind == 'restore' ? trash! : root,
    );
    await _mutations.validateManagedDirectoryPath(
      Directory(to),
      allowedRoot: kind == 'trash' ? trash! : root,
    );
  }

  Future<void> _validateOperation(
    _Move operation, {
    bool history = false,
  }) async {
    if (operation.kind != 'move') {
      final recovery = trash;
      final allowed = trashAllowedRoot;
      if (recovery == null || allowed == null) {
        throw StateError('Recovery storage is not configured');
      }
      await _mutations.validateManagedDirectoryPath(
        recovery,
        allowedRoot: allowed,
      );
      final recoveryPath = operation.kind == 'trash'
          ? operation.to
          : operation.from;
      final recoveryId = operation.kind == 'trash'
          ? operation.id
          : operation.recoveryId;
      final libraryPath = operation.kind == 'trash'
          ? operation.from
          : operation.to;
      if (!p.equals(recoveryPath, p.join(recovery.path, recoveryId!)) ||
          !p.isWithin(p.normalize(p.absolute(root.path)), libraryPath)) {
        throw const FormatException(
          'Recovery journal paths do not match its receipt',
        );
      }
    }
    if (!history) await _validate(operation.from, operation.to, operation.kind);
  }

  Future<void> _finish(_Move operation) async {
    await _validateOperation(operation);
    final source = await observeDirectory(operation.from);
    final destination = await observeDirectory(operation.to);
    if (source.status != 1 ||
        destination.status != 0 ||
        destination.identity != operation.identity) {
      throw StateError(
        'Move identity is ambiguous; retained journal ${operation.id}',
      );
    }
    // Recovery must satisfy the same durability checks as the first attempt.
    await syncDirectory(p.dirname(operation.from));
    if (p.dirname(operation.from) != p.dirname(operation.to)) {
      await syncDirectory(p.dirname(operation.to));
    }
    await repoint(operation.from, operation.to, operation.id);
    await testHook?.call(RepertoireMoveStep.referencesUpdated);
    if ((await observeDirectory(operation.to)).identity != operation.identity ||
        (await observeDirectory(operation.from)).status != 1) {
      throw StateError('Directory binding changed during reference migration');
    }
    await _write(operation.withState('completed'));
    await testHook?.call(RepertoireMoveStep.completed);
  }

  Future<List<_Move>> _records() async {
    if (!await journals.exists()) return [];
    final files = await journals
        .list()
        .where((entry) => entry is File && p.extension(entry.path) == '.json')
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    final records = <_Move>[];
    for (final file in files) {
      final raw = await readTextFileSafely(file);
      if (raw == null) continue;
      final operation = _Move.parse(
        jsonDecode(raw),
        p.basenameWithoutExtension(file.path),
      );
      records.add(operation);
    }
    final byId = {for (final record in records) record.id: record};
    final completedRestores = <String>{};
    for (final record in records.where((r) => r.kind == 'restore')) {
      final original = byId[record.recoveryId];
      if (original == null ||
          original.kind != 'trash' ||
          original.state != 'completed' ||
          record.from != original.to ||
          record.identity != original.identity ||
          (record.state == 'completed' &&
              !completedRestores.add(original.id))) {
        throw const FormatException(
          'Restore receipt does not match its deletion',
        );
      }
    }
    return records;
  }

  Future<void> _recover() async {
    for (final operation in await _records()) {
      if (operation.state != 'pending') continue;
      try {
        await _validateOperation(operation);
        final source = await observeDirectory(operation.from);
        final destination = await observeDirectory(operation.to);
        if (source.status == 0 &&
            source.identity == operation.identity &&
            destination.status == 1) {
          // The intent was durable but the rename never happened. Do not
          // execute a previously uncommitted user action during startup.
          await _write(operation.withState('cancelled'));
        } else {
          await _finish(operation);
        }
      } catch (error) {
        throw RepertoireRecoveryRequired(operation.id, error);
      }
    }
  }

  Future<void> _write(_Move operation, {bool create = false}) async {
    await writeTextFileAtomically(
      File(p.join(journals.path, '${operation.id}.json')),
      jsonEncode(operation.toJson()),
      createOnly: create,
    );
    await syncDirectory(journals.path);
    await syncDirectory(journals.parent.path);
  }
}

class _Move {
  const _Move(
    this.id,
    this.from,
    this.to,
    this.identity,
    this.state, {
    this.kind = 'move',
    this.recoveryId,
  });
  final String id;
  final String from;
  final String to;
  final String identity;
  final String state;
  final String kind;
  final String? recoveryId;
  _Move withState(String value) =>
      _Move(id, from, to, identity, value, kind: kind, recoveryId: recoveryId);
  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'from': from,
    'to': to,
    'identity': identity,
    'state': state,
    'kind': kind,
    'recoveryId': ?recoveryId,
  };
  static _Move parse(Object? value, String fileId) {
    if (!RegExp(r'^[0-9]+-[0-9a-f]+$').hasMatch(fileId) ||
        value is! Map ||
        value['version'] != 1 ||
        value['id'] != fileId ||
        value['from'] is! String ||
        value['to'] is! String ||
        value['identity'] is! String ||
        !{'move', 'trash', 'restore'}.contains(value['kind'] ?? 'move') ||
        (value['kind'] == 'restore' &&
            (value['recoveryId'] is! String ||
                !RegExp(
                  r'^[0-9]+-[0-9a-f]+$',
                ).hasMatch(value['recoveryId'] as String))) ||
        !{'pending', 'completed', 'cancelled'}.contains(value['state'])) {
      throw const FormatException(
        'Invalid repertoire move journal; retained for recovery',
      );
    }
    return _Move(
      fileId,
      value['from'] as String,
      value['to'] as String,
      value['identity'] as String,
      value['state'] as String,
      kind: (value['kind'] as String?) ?? 'move',
      recoveryId: value['recoveryId'] as String?,
    );
  }
}
