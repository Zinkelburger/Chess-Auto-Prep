import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';

/// Every version the store replaces, kept where a mistake in Documents cannot
/// reach it: `<support>/backups/<document id>/`, one gzipped copy per version
/// named by its commit time and content hash, plus an `index.json` listing
/// them oldest first.
///
/// Versions follow the document's identity rather than its name, so a rename
/// or move made through the store carries the history with it ([adopt]). A
/// rename made by another program starts a new history; the old one stays
/// under the old id and is still readable by hand.
///
/// Nothing here removes anything. Retention and the restore screen are later
/// steps.
final class BackupArchive {
  BackupArchive(this.root);

  /// The `backups` directory under Support.
  final Directory root;

  /// Records [bytes] as the newest version of the document with [id], unless
  /// they are already the newest one recorded.
  ///
  /// The caller records what it is about to replace *before* replacing it, and
  /// abandons the write on [BackupFailed]: a version that could not be kept is
  /// a reason not to overwrite it.
  Future<BackupOutcome> record({
    required String id,
    required String documentPath,
    required List<int> bytes,
    required String hash,
  }) async {
    final folder = Directory(p.join(root.path, id));
    try {
      await folder.create(recursive: true);
      final index = await _readIndex(folder);
      if (index.isNotEmpty && index.last.hash == hash) {
        return const BackupSkipped();
      }
      final time = DateTime.now().toUtc();
      final name = '${_stamp(time)}-${hash.substring(0, 8)}.pgn.gz';
      await replaceFile(p.join(folder.path, name), gzip.encode(bytes));
      final version = BackupVersion(
        file: name,
        time: time,
        size: bytes.length,
        hash: hash,
      );
      await _writeIndex(folder, documentPath, [...index, version]);
      return const BackupRecorded();
    } on Object catch (error) {
      log.e('record the previous version of $documentPath', error);
      return BackupFailed('$error');
    }
  }

  /// Moves the history of [from] to [to] after the document moved. A failure
  /// leaves the history under [from], where it is still readable, so it never
  /// fails the move itself.
  Future<void> adopt({
    required String from,
    required String to,
    required String documentPath,
  }) async {
    final source = Directory(p.join(root.path, from));
    if (!await source.exists()) return;
    try {
      final destination = Directory(p.join(root.path, to));
      await movePathNoReplace(source.path, destination.path);
      final index = await _readIndex(destination);
      await _writeIndex(destination, documentPath, index);
    } on Object catch (error) {
      log.w('move the kept versions of $documentPath', error);
    }
  }

  Future<List<BackupVersion>> _readIndex(Directory folder) async {
    final file = File(p.join(folder.path, _indexName));
    if (!await file.exists()) return const [];
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final versions = json['versions'] as List<Object?>;
    return [
      for (final version in versions)
        BackupVersion.fromJson(version as Map<String, Object?>),
    ];
  }

  Future<void> _writeIndex(
    Directory folder,
    String documentPath,
    List<BackupVersion> versions,
  ) async {
    final json = {
      'path': documentPath,
      'versions': [for (final version in versions) version.toJson()],
    };
    await replaceFile(
      p.join(folder.path, _indexName),
      utf8.encode(jsonEncode(json)),
    );
  }
}

const _indexName = 'index.json';

/// The id a document's versions are kept under: a hash of its path relative to
/// the documents root, with separators spelled the same way on every platform.
String backupId(String relativePath) {
  final canonical = p.split(relativePath).join('/');
  return sha256.convert(utf8.encode(canonical)).toString().substring(0, 16);
}

/// `20260919T203104123Z`, sortable and legal as a file name everywhere.
String _stamp(DateTime utc) {
  final iso = utc.toIso8601String();
  return iso.replaceAll(RegExp('[-:.]'), '');
}

final class BackupVersion {
  const BackupVersion({
    required this.file,
    required this.time,
    required this.size,
    required this.hash,
  });

  factory BackupVersion.fromJson(Map<String, Object?> json) => BackupVersion(
    file: json['file']! as String,
    time: DateTime.parse(json['time']! as String),
    size: json['size']! as int,
    hash: json['hash']! as String,
  );

  final String file;
  final DateTime time;
  final int size;

  /// SHA-256 of the uncompressed bytes.
  final String hash;

  Map<String, Object?> toJson() => {
    'file': file,
    'time': time.toIso8601String(),
    'size': size,
    'hash': hash,
  };
}

sealed class BackupOutcome {
  const BackupOutcome();
}

final class BackupRecorded extends BackupOutcome {
  const BackupRecorded();
}

/// These bytes are already the newest version kept.
final class BackupSkipped extends BackupOutcome {
  const BackupSkipped();
}

final class BackupFailed extends BackupOutcome {
  const BackupFailed(this.detail);

  final String detail;
}
