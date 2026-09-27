import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:document_file_io/document_file_io.dart' show syncDirectory;
import '../../features/documents/repositories/workspace_recovery_store.dart';
import '../../utils/atomic_file.dart';
import 'workspace_recovery_codec.dart';

/// Each app instance owns one random checkpoint and a lifetime lease. A crashed
/// process releases its lease; other live sessions never enter the recovery UI.
/// Checkpoints and resolution receipts use the existing journaled atomic writer.
class FileWorkspaceRecoveryStore<S> implements WorkspaceRecoveryStore<S> {
  FileWorkspaceRecoveryStore({
    required this._directory,
    required this.codec,
    AtomicFileWriter? writer,
  }) : _writer = writer ?? AtomicFileWriter();
  final Future<Directory> Function() _directory;
  final AtomicFileWriter _writer;
  final WorkspaceRecoveryCodec<S> codec;
  static final _idPattern = RegExp(r'^[a-f0-9]{32}$');
  String? _id;
  Database? _lease;
  bool _closed = false;
  bool _hasCheckpoint = false;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  String _digest(String text) => sha256.convert(utf8.encode(text)).toString();
  Future<void> _sync(Directory root) async {
    if (Platform.isLinux) await syncDirectory(root.path);
  }

  Future<void> _own(Directory root) async {
    if (_closed) throw StateError('Recovery store is closed');
    if (_id != null) return;
    await root.create(recursive: true);
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _lease = await _acquire(root, id);
    if (_lease == null) {
      throw StateError('Recovery session ID is already in use');
    }
    _id = id;
  }

  Future<Database?> _acquire(Directory root, String id) async {
    final path = p.join(await root.resolveSymbolicLinks(), '$id.lease.sqlite');
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('Unsafe recovery lease');
    }
    // SQLite transactions distinguish connections in the same process/isolate;
    // POSIX record locks do not, and closing a second handle can release them.
    final lease = sqlite3.open(path);
    try {
      lease.execute('PRAGMA busy_timeout = 0');
      lease.execute('BEGIN IMMEDIATE');
      return lease;
    } on SqliteException catch (error) {
      lease.close();
      if (error.resultCode == 5 || error.resultCode == 6) return null;
      rethrow;
    } catch (_) {
      lease.close();
      rethrow;
    }
  }

  Future<T?> _inactive<T>(
    Directory root,
    String id,
    Future<T> Function() action,
  ) async {
    final lease = await _acquire(root, id);
    if (lease == null) return null;
    try {
      return await action();
    } finally {
      lease.close();
    }
  }

  Map<String, dynamic> _record(String text) {
    final data = jsonDecode(text) as Map<String, dynamic>;
    if (data['schema'] != 1 || data['resolved'] is! bool) {
      throw const FormatException('Unsupported recovery record');
    }
    if (data['payloadSha256'] != _digest(jsonEncode(data['snapshot']))) {
      throw const FormatException('Recovery content checksum mismatch');
    }
    return data;
  }

  @override
  Future<WorkspaceRecoveryListing<S>> list() => _serial(() async {
    final root = await _directory();
    if (!await root.exists()) return WorkspaceRecoveryListing<S>([]);
    await recoverAtomicWritesInDirectory(root);
    final entries = <WorkspaceRecoveryEntry<S>>[];
    var unreadable = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (!entity.path.endsWith('.json')) continue;
      final id = p.basenameWithoutExtension(entity.path);
      if (!_idPattern.hasMatch(id)) continue;
      try {
        if (entity is! File) {
          throw const FormatException('Non-file recovery record');
        }
        await _inactive(root, id, () async {
          final text = await readTextFileSafely(entity);
          if (text == null) {
            throw const FormatException('Missing recovery record');
          }
          final data = _record(text);
          if (data['resolved'] as bool) return;
          entries.add(
            WorkspaceRecoveryEntry<S>(
              id: id,
              revision: _digest(text),
              updatedAt: DateTime.parse(data['updatedAt'] as String),
              snapshot: codec.decode(data['snapshot'] as Map<String, dynamic>),
            ),
          );
        });
      } catch (_) {
        unreadable++;
      }
    }
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return WorkspaceRecoveryListing<S>(entries, unreadable: unreadable);
  });
  @override
  Future<void> write(S snapshot) => _serial(() async {
    final root = await _directory();
    await _own(root);
    final payload = codec.encode(snapshot);
    final text = jsonEncode({
      'schema': 1,
      'resolved': !codec.needsRecovery(snapshot),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'snapshot': payload,
      'payloadSha256': _digest(jsonEncode(payload)),
    });
    await _writer.writeText(
      File(p.join(root.path, '$_id.json')),
      text,
      createOnly: !_hasCheckpoint,
    );
    _hasCheckpoint = true;
    await _sync(root);
  });
  @override
  Future<void> resolve(WorkspaceRecoveryEntry<S> entry) => _serial(() async {
    if (!_idPattern.hasMatch(entry.id)) {
      throw ArgumentError('Invalid recovery ID');
    }
    final root = await _directory();
    final resolved = await _inactive(root, entry.id, () async {
      await updateTextFileAtomically(
        File(p.join(root.path, '${entry.id}.json')),
        (text) {
          if (text != null && _digest(text) != entry.revision) {
            final previous = _record(text);
            if (previous['resolved'] == true) {
              previous['resolved'] = false;
              if (_digest(jsonEncode(previous)) == entry.revision) return text;
            }
          }
          if (text == null || _digest(text) != entry.revision) {
            throw StateError(
              'Recovery entry changed; refresh before resolving',
            );
          }
          final data = _record(text)..['resolved'] = true;
          return jsonEncode(data);
        },
      );
      await _sync(root);
      return true;
    });
    if (resolved != true) throw StateError('Recovery entry is still in use');
  });
  @override
  Future<void> close() => _serial(() async {
    _closed = true;
    _lease?.close();
    _lease = null;
  });
}
