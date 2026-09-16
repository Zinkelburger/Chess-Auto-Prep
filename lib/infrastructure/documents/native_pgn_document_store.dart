import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_text_reader.dart';
import '../../utils/pgn_compression.dart';

/// Native-identity PGN store. All reads/checks/commits share the existing
/// cross-isolate/process mutex; native reads and flushes run off the UI isolate.
/// Final symlinks, hardlinks and files above 512 MiB fail closed. Parent aliases
/// are resolved before locking. Arbitrary external editors can still race the
/// last validation and rename: this is not filesystem compare-and-swap.
class NativePgnDocumentStore implements PgnDocumentStore {
  NativePgnDocumentStore({
    AtomicFileWriter? writer,
    Future<NativeFileObservation> Function(String)? observe,
    Future<void> Function(String)? flushDirectory,
  }) : _writer = writer ?? AtomicFileWriter(),
       _observe = observe ?? observeFile,
       _flushDirectory = flushDirectory ?? syncDirectory;

  final AtomicFileWriter _writer;
  final Future<NativeFileObservation> Function(String) _observe;
  final Future<void> Function(String) _flushDirectory;

  Future<String> _path(String path) async {
    final absolute = p.normalize(p.absolute(path));
    final parent = Directory(p.dirname(absolute));
    // Resolve existing ancestors too when create's immediate parent is new.
    Future<String> resolve(Directory dir) async {
      if (await dir.exists()) return dir.resolveSymbolicLinks();
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw FileSystemException('No existing ancestor', path);
      }
      return p.join(await resolve(parent), p.basename(dir.path));
    }

    return p.join(await resolve(parent), p.basename(absolute));
  }

  Future<PgnSnapshot> _snapshot(
    String path,
    NativeFileObservation observation,
  ) async {
    if (observation.status != 0 ||
        observation.identity == null ||
        observation.bytes == null ||
        observation.sha256Hex == null) {
      throw FileSystemException(
        'File identity unavailable, changed, or unsupported',
        path,
        OSError('Native observation', observation.error),
      );
    }
    return PgnSnapshot(
      path: path,
      revision: PgnRevision(
        documentId: path,
        nativeIdentity: observation.identity!,
        sha256: observation.sha256Hex!,
      ),
      content: await _decode(observation.bytes!),
    );
  }

  /// Retain exact baseline bytes before publication. These versions are never
  /// silently pruned. A future recovery UI can verify the digest-named copy.
  Future<String> _preserve(String path, NativeFileObservation initial) async {
    final token = sha256.convert(
      utf8.encode('$path:${initial.identity}:${initial.sha256Hex}'),
    );
    final history = File(
      p.join(p.dirname(path), '.cap-pgn-history', '$token.bytes'),
    );
    final writer = AtomicFileWriter();
    await writer.transaction(history, (transaction) async {
      final existing = await _observe(history.path);
      if (existing.status == 0 && existing.sha256Hex == initial.sha256Hex) {
        return;
      }
      if (existing.status != 1) {
        throw FileSystemException(
          'Recovery baseline cannot be verified',
          history.path,
        );
      }
      await transaction.writeBytes(
        initial.bytes!,
        createOnly: true,
        validate: (_) async {},
        installNew: (stage, target) => installNewFile(stage.path, target.path),
      );
      await _flushDirectory(history.parent.path);
    });
    return history.path;
  }

  @override
  Future<PgnOpenResult> open(String path) async {
    try {
      final canonical = await _path(path);
      return await _writer.transaction(File(canonical), (_) async {
        final value = await _observe(canonical);
        if (value.status == 1) return const PgnMissing();
        return PgnOpened(await _snapshot(canonical, value));
      });
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  @override
  Future<PgnWriteResult> create(String path, String content) =>
      _write(path, null, content);

  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) =>
      _write(baseline.path, baseline, content);

  Future<PgnWriteResult> _write(
    String path,
    PgnSnapshot? baseline,
    String content,
  ) async {
    try {
      final canonical = await _path(path);
      return await _writer.transaction(File(canonical), (transaction) async {
        final initial = await _observe(canonical);
        PgnSnapshot? before;
        if (initial.status == 0) {
          before = await _snapshot(canonical, initial);
        } else if (initial.status != 1) {
          return PgnWriteFailed(
            FileSystemException('Cannot verify document identity', canonical),
          );
        }
        if (baseline == null && before != null) return const PgnNameCollision();
        if (baseline != null && before?.revision != baseline.revision) {
          return PgnConflict(before);
        }
        final compressed =
            initial.bytes != null && looksGzipped(initial.bytes!);
        final prepared = await _encode(content, compressed);
        final bytes = prepared.bytes;
        final recoveryPath = before == null
            ? null
            : await _preserve(canonical, initial);
        String? stagedIdentity;
        bool validated = false;
        try {
          await transaction.writeBytes(
            bytes,
            createOnly: baseline == null,
            installNew: (stage, target) =>
                installNewFile(stage.path, target.path),
            validate: (staged) async {
              final stage = await _observe(staged.path);
              if (stage.status != 0 || stage.identity == null) {
                throw FileSystemException(
                  'Cannot verify staged file',
                  staged.path,
                );
              }
              stagedIdentity = stage.identity;
              final current = await _observe(canonical);
              if (baseline == null) {
                if (current.status == 0) throw const _Collision();
                if (current.status != 1) {
                  throw FileSystemException(
                    'Cannot verify destination absence',
                    canonical,
                  );
                }
              } else {
                if (current.status == 1) throw const _Conflict(null);
                final snapshot = await _snapshot(canonical, current);
                if (snapshot.revision != baseline.revision) {
                  throw _Conflict(snapshot);
                }
              }
              validated = true;
            },
          );
          await _flushDirectory(p.dirname(canonical));
          final after = await _snapshot(canonical, await _observe(canonical));
          if (after.revision.nativeIdentity != stagedIdentity ||
              after.revision.sha256 != prepared.digest) {
            return PgnWriteUncertain(
              error: StateError(
                'Installed document changed before acknowledgement',
              ),
              before: before,
              recoveryPath: recoveryPath,
              observed: after,
            );
          }
          return PgnSaved(
            before: before,
            after: after,
            recoveryPath: recoveryPath,
          );
        } on _Conflict catch (conflict) {
          return PgnConflict(conflict.current);
        } on NativeNameCollision {
          return const PgnNameCollision();
        } on AtomicNameCollision {
          return const PgnNameCollision();
        } on _Collision {
          return const PgnNameCollision();
        } catch (error) {
          PgnSnapshot? observed;
          try {
            final value = await _observe(canonical);
            if (value.status == 0) observed = await _snapshot(canonical, value);
          } catch (_) {
            /* The read failure never authorizes another write. */
          }
          if (validated &&
              (observed == null || observed.revision != before?.revision)) {
            return PgnWriteUncertain(
              error: error,
              before: before,
              recoveryPath: recoveryPath,
              observed: observed,
            );
          }
          return PgnWriteFailed(error);
        }
      });
    } catch (error) {
      return PgnWriteFailed(error);
    }
  }
}

class _Conflict implements Exception {
  const _Conflict(this.current);
  final PgnSnapshot? current;
}

class _Collision implements Exception {
  const _Collision();
}

Future<String> _decode(List<int> bytes) =>
    Isolate.run(() => decodeTextBytes(maybeGunzip(bytes)));

Future<({List<int> bytes, String digest})> _encode(
  String content,
  bool compressed,
) => Isolate.run(() {
  final raw = utf8.encode(content);
  final bytes = compressed ? gzipBytes(raw) : raw;
  return (bytes: bytes, digest: sha256.convert(bytes).toString());
});
