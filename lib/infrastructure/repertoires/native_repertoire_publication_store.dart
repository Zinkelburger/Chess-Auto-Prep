import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../../features/documents/models/pgn_document.dart';
import '../../features/repertoires/models/repertoire_creation.dart';
import '../../features/repertoires/models/repertoire_publication.dart';
import '../../features/repertoires/models/repertoire_recovery_required.dart';
import '../../services/storage/file_mutation_service.dart';
import '../../utils/atomic_file.dart';
import '../../utils/safe_file_name.dart';
import '../documents/native_pgn_document_store.dart';
import 'repertoire_directory_mutations.dart';

enum RepertoirePublicationStep {
  chapterWritten,
  staged,
  prepared,
  installed,
  completed,
}

/// A complete new folder is published with one native exclusive rename. Private
/// partial imports and receipts are retained; recovery never publishes a staged
/// draft that had not reached the commit intent. Call recover under the shared
/// repertoire domain lock, as provided by IOStorageService.
class NativeRepertoirePublicationStore {
  NativeRepertoirePublicationStore({
    required this.root,
    required this.guardCommit,
    this.testHook,
  });
  final Directory root;
  final Future<T> Function<T>(Future<T> Function() action) guardCommit;
  final Future<void> Function(RepertoirePublicationStep)? testHook;
  final _mutations = FileMutationService();
  final _documents = NativePgnDocumentStore();
  Directory get _staging =>
      Directory(p.join(root.path, RepertoireDirectoryMutations.stagingName));
  Directory _batch(String id) => Directory(p.join(_staging.path, id));
  Directory _payload(String id) =>
      Directory(p.join(_batch(id).path, 'payload'));
  File _manifest(String id) =>
      File(p.join(_batch(id).path, 'publication.json'));
  String _target(_Receipt receipt) => p.join(root.path, receipt.name);

  Future<void> _validateStaging() =>
      _mutations.validateManagedDirectoryPath(_staging, allowedRoot: root);

  Future<RepertoireCreationResult> publish(
    RepertoirePublication plan, {
    Future<void> Function(String path, String content)? createDocument,
  }) async {
    if (plan.name == RepertoireDirectoryMutations.stagingName) {
      throw ArgumentError('That repertoire name is reserved.');
    }
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final payload = _payload(id);
    final files = <String, _ChapterRevision>{};
    late _Receipt receipt;
    try {
      await _validateStaging();
      await _staging.create(recursive: true);
      await _validateStaging();
      await _mutations.createDirectoryNoReplace(_batch(id), allowedRoot: root);
      await _mutations.createDirectoryNoReplace(payload, allowedRoot: root);
      // Preserve the input separately from the transformed publication.
      if (plan.sourceContent != null) {
        await _create(
          p.join(_batch(id).path, 'source.pgn'),
          plan.sourceContent!,
        );
      }
      for (final entry in plan.chapters.entries) {
        final path = p.join(payload.path, entry.key);
        await (createDocument?.call(path, entry.value) ??
            _create(path, entry.value));
        final observed = await observeFile(path);
        final expected = sha256.convert(utf8.encode(entry.value)).toString();
        if (observed.status != 0 ||
            observed.identity == null ||
            observed.sha256Hex != expected) {
          throw StateError('Prepared chapter did not match the import');
        }
        files[entry.key] = _ChapterRevision(observed.identity!, expected);
        await testHook?.call(RepertoirePublicationStep.chapterWritten);
      }
      final directory = await observeDirectory(payload.path);
      if (directory.status != 0 || directory.identity == null) {
        throw StateError('Cannot identify the prepared repertoire');
      }
      receipt = _Receipt(id, plan.name, directory.identity!, files, 'staged');
      await syncDirectory(payload.path);
      await _write(receipt, create: true);
      await syncDirectory(_staging.path);
      await syncDirectory(root.path);
      await testHook?.call(RepertoirePublicationStep.staged);
    } catch (error) {
      throw RepertoirePreparationFailed(error);
    }

    await guardCommit(() async {
      var prepared = false;
      try {
        await for (final sibling in root.list(followLinks: false)) {
          if (p.basename(sibling.path).toLowerCase() ==
              plan.name.toLowerCase()) {
            throw RepertoireExistsException(plan.name);
          }
        }
        await _validatePayload(payload, receipt);
        await _mutations.moveDirectoryNoReplace(
          payload,
          Directory(_target(receipt)),
          allowedRoot: root,
          beforeMove: () async {
            prepared = true;
            receipt = receipt.withState('pending');
            await _write(receipt);
            await testHook?.call(RepertoirePublicationStep.prepared);
          },
          installNoReplace: () =>
              movePathNoReplace(payload.path, _target(receipt)),
          afterMove: () async =>
              testHook?.call(RepertoirePublicationStep.installed),
        );
        await _finish(receipt);
        await testHook?.call(RepertoirePublicationStep.completed);
      } on NativeNameCollision {
        await _write(receipt.withState('cancelled'));
        throw RepertoireExistsException(plan.name);
      } catch (error) {
        if (prepared) throw RepertoireRecoveryRequired(receipt.id, error);
        if (await FileSystemEntity.type(_target(receipt), followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw RepertoireExistsException(plan.name);
        }
        rethrow;
      }
    });
    final paths = [
      for (final name in plan.chapters.keys) p.join(_target(receipt), name),
    ];
    return RepertoireCreationResult(
      directoryPath: _target(receipt),
      chapterPath: paths.first,
      chapterPaths: paths,
      gameCount: plan.gameCount,
    );
  }

  Future<void> _create(String path, String text) async {
    final result = await _documents.create(path, text);
    switch (result) {
      case PgnSaved():
        return;
      case PgnWriteFailed(:final error):
        throw error;
      case PgnWriteUncertain(:final error):
        throw error;
      default:
        throw StateError('Could not confirm prepared file: $result');
    }
  }

  Future<void> _validatePayload(Directory directory, _Receipt receipt) async {
    await _mutations.validateManagedDirectoryPath(directory, allowedRoot: root);
    final observed = await observeDirectory(directory.path);
    if (observed.status != 0 || observed.identity != receipt.identity) {
      throw StateError('Publication directory identity changed');
    }
    final entries = await directory.list(followLinks: false).toList();
    if (entries.length != receipt.files.length) {
      throw StateError('Publication contents changed');
    }
    for (final entry in entries) {
      final expected = receipt.files[p.basename(entry.path)];
      if (entry is! File || expected == null) {
        throw StateError('Unexpected publication entry');
      }
      final file = await observeFile(entry.path);
      if (file.status != 0 ||
          file.identity != expected.identity ||
          file.sha256Hex != expected.digest) {
        throw StateError('Publication chapter changed');
      }
    }
  }

  Future<void> _finish(_Receipt receipt) async {
    await _validateStaging();
    if ((await observeDirectory(_payload(receipt.id).path)).status != 1) {
      throw StateError('Publication source still exists');
    }
    await syncDirectory(_batch(receipt.id).path);
    await syncDirectory(root.path);
    await _validatePayload(Directory(_target(receipt)), receipt);
    await _write(receipt.withState('completed'));
  }

  Future<void> _write(_Receipt receipt, {bool create = false}) async {
    await _mutations.validateManagedDirectoryPath(
      _batch(receipt.id),
      allowedRoot: root,
    );
    await writeTextFileAtomically(
      _manifest(receipt.id),
      jsonEncode(receipt.toJson()),
      createOnly: create,
    );
    await syncDirectory(_batch(receipt.id).path);
  }

  /// No caller may mutate the library until this returns successfully.
  Future<void> recover() async {
    await _validateStaging();
    if (!await _staging.exists()) return;
    final batches = await _staging.list(followLinks: false).toList();
    batches.sort((a, b) => a.path.compareTo(b.path));
    for (final batch in batches) {
      final id = p.basename(batch.path);
      if (!RegExp(r'^[0-9]+-[0-9a-f]+$').hasMatch(id)) {
        throw const FormatException('Invalid publication directory');
      }
      await _mutations.validateManagedDirectoryPath(
        Directory(batch.path),
        allowedRoot: root,
      );
      if (await FileSystemEntity.type(_manifest(id).path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException(
          'Publication receipts cannot be symbolic links',
        );
      }
      final text = await readTextFileSafely(_manifest(id));
      if (text == null) {
        continue; // Incomplete private preparation, never published.
      }
      final receipt = _Receipt.parse(jsonDecode(text), id);
      if (receipt.state != 'pending') continue;
      try {
        final source = await observeDirectory(_payload(id).path);
        final target = await observeDirectory(_target(receipt));
        if (source.status == 0 &&
            source.identity == receipt.identity &&
            target.status == 1) {
          await _write(receipt.withState('cancelled'));
        } else {
          await _finish(receipt);
        }
      } catch (error) {
        throw RepertoireRecoveryRequired(id, error);
      }
    }
  }
}

class _ChapterRevision {
  const _ChapterRevision(this.identity, this.digest);
  final String identity;
  final String digest;
  Map<String, String> toJson() => {'identity': identity, 'digest': digest};
}

class _Receipt {
  const _Receipt(this.id, this.name, this.identity, this.files, this.state);
  final String id;
  final String name;
  final String identity;
  final Map<String, _ChapterRevision> files;
  final String state;
  _Receipt withState(String value) =>
      _Receipt(id, name, identity, files, value);
  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'identity': identity,
    'state': state,
    'files': {
      for (final entry in files.entries) entry.key: entry.value.toJson(),
    },
  };
  static _Receipt parse(Object? value, String id) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['id'] != id ||
        value['name'] is! String ||
        value['identity'] is! String ||
        value['files'] is! Map ||
        !{
          'staged',
          'pending',
          'completed',
          'cancelled',
        }.contains(value['state'])) {
      throw const FormatException('Invalid publication receipt');
    }
    final name = requireSafeFileName(value['name'] as String);
    if (name != value['name'] ||
        name == RepertoireDirectoryMutations.stagingName) {
      throw const FormatException('Invalid publication destination');
    }
    final files = <String, _ChapterRevision>{};
    for (final entry in (value['files'] as Map).entries) {
      final key = entry.key;
      final fields = entry.value;
      if (key is! String ||
          !key.endsWith('.pgn') ||
          fields is! Map ||
          fields['identity'] is! String ||
          fields['digest'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fields['digest'] as String)) {
        throw const FormatException('Invalid publication chapter');
      }
      files[key] = _ChapterRevision(
        fields['identity'] as String,
        fields['digest'] as String,
      );
    }
    // Apply the same path and duplicate validation as new publications.
    RepertoirePublication(
      name: name,
      chapters: {for (final key in files.keys) key: ''},
      gameCount: 0,
    );
    return _Receipt(
      id,
      name,
      value['identity'] as String,
      files,
      value['state'] as String,
    );
  }
}
