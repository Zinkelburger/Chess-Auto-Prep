import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../../features/repertoires/models/repertoire_recovery_required.dart';
import '../../services/storage/file_mutation_service.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_operation_lock.dart';

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
    FileMutationService? mutations,
  }) : _mutations = mutations ?? FileMutationService();

  final Directory root;
  final Directory journals;
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
        await _recover();
        return action();
      },
    );
  }

  Future<void> recover() => guard(() async {});

  Future<void> move(String from, String to) => guard(() async {
    if (p.equals(p.normalize(from), p.normalize(to))) return;
    final source = Directory(p.normalize(p.absolute(from)));
    final destination = Directory(p.normalize(p.absolute(to)));
    await _validate(source.path, destination.path);
    final observation = await observeDirectory(source.path);
    if (observation.status != 0 || observation.identity == null) {
      throw FileSystemException(
        'Cannot verify source directory identity',
        from,
      );
    }
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final operation = _Move(
      id,
      source.path,
      destination.path,
      observation.identity!,
      'pending',
    );
    var prepared = false;
    try {
      await _mutations.moveDirectoryNoReplace(
        source,
        destination,
        allowedRoot: root,
        installNoReplace: () => moveDirectoryNew(source.path, destination.path),
        beforeMove: () async {
          if ((await observeDirectory(source.path)).identity !=
              operation.identity) {
            throw FileSystemException('Source changed before rename', from);
          }
          await _write(operation, create: true);
          prepared = true;
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
  });

  Future<void> _validate(String from, String to) async {
    if (p.equals(from, to) || p.isWithin(from, to)) {
      throw const UnsafeFileMutation('A directory cannot move into itself.');
    }
    await _mutations.validateManagedDirectoryPath(
      Directory(from),
      allowedRoot: root,
    );
    await _mutations.validateManagedDirectoryPath(
      Directory(to),
      allowedRoot: root,
    );
  }

  Future<void> _finish(_Move operation) async {
    await _validate(operation.from, operation.to);
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

  Future<void> _recover() async {
    if (!await journals.exists()) return;
    final files = await journals
        .list()
        .where((entry) => entry is File && p.extension(entry.path) == '.json')
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final raw = await readTextFileSafely(file);
      if (raw == null) continue;
      final operation = _Move.parse(
        jsonDecode(raw),
        p.basenameWithoutExtension(file.path),
      );
      if (operation.state != 'pending') continue;
      try {
        await _validate(operation.from, operation.to);
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
  const _Move(this.id, this.from, this.to, this.identity, this.state);
  final String id;
  final String from;
  final String to;
  final String identity;
  final String state;
  _Move withState(String value) => _Move(id, from, to, identity, value);
  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'from': from,
    'to': to,
    'identity': identity,
    'state': state,
  };
  static _Move parse(Object? value, String fileId) {
    if (!RegExp(r'^[0-9]+-[0-9a-f]+$').hasMatch(fileId) ||
        value is! Map ||
        value['version'] != 1 ||
        value['id'] != fileId ||
        value['from'] is! String ||
        value['to'] is! String ||
        value['identity'] is! String ||
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
    );
  }
}
