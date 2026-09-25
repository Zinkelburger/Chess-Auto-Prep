import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backup_relocation.dart';

/// Every version the store replaces, kept where a mistake in Documents cannot
/// reach it: `<support>/backups/<document id>/`, one plain copy per version
/// named by its commit time and content hash, plus an `index.json` listing
/// them oldest first. Earlier builds kept versions gzipped; those are still
/// read, by their magic bytes rather than their name.
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

  /// Plans without writing; the relocation journal owns this exact result.
  Future<BackupMove> planMove({
    required String fromId,
    required String toId,
    required String documentPath,
    required String operationId,
  }) => BackupRelocation(root).planMove(
    fromId: fromId,
    toId: toId,
    documentPath: documentPath,
    operationId: operationId,
  );

  Future<void> validateMove(BackupMove move, {bool allowAfter = true}) =>
      BackupRelocation(root).validateMove(move, allowAfter: allowAfter);

  Future<void> applyMove(
    BackupMove move, {
    Future<void> Function(BackupMoveStep)? testHook,
  }) => BackupRelocation(root).applyMove(move, testHook: testHook);

  /// Where the versions of the document with [id] are kept, for telling
  /// someone where to find them.
  Directory folderFor(String id) => Directory(p.join(root.path, id));

  /// When the document with [id] has a version whose bytes hash to [hash],
  /// what is known about it; null when it has none.
  ///
  /// It is how a restore proves it is putting back something this store kept
  /// rather than bytes a caller made up: nothing else compares what a
  /// restore writes against anything.
  Future<BackupVersion?> versionWithHash(String id, String hash) async {
    try {
      final index = await _readIndex(folderFor(id));
      return index.versions.where((version) => version.hash == hash).lastOrNull;
    } on Object catch (error) {
      log.e('look for a kept version of $id', error);
      return null;
    }
  }

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
    final folder = folderFor(id);
    try {
      await folder.create(recursive: true);
      final index = await _readIndex(folder);
      if (index.versions.isNotEmpty && index.versions.last.hash == hash) {
        return const BackupSkipped();
      }
      final time = DateTime.now().toUtc();
      final name = '${_stamp(time)}-${hash.substring(0, 8)}$_versionSuffix';
      // Through the atomic writer, like every other file this app publishes:
      // these bytes are the only copy of what the save is about to replace,
      // and a machine that stops half way through writing them must leave
      // either nothing under that name or the whole version.
      await replaceFile(p.join(folder.path, name), bytes);
      final version = BackupVersion(
        file: name,
        time: time,
        size: bytes.length,
        hash: hash,
      );
      await _writeIndex(folder, documentPath, index, append: version);
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
    final source = folderFor(from);
    if (!await source.exists()) return;
    try {
      final destination = folderFor(to);
      if (await destination.exists()) {
        await _adoptOverOccupant(source, destination);
      } else {
        await movePathNoReplace(source.path, destination.path);
      }
      final index = await _readIndex(destination);
      await _writeIndex(destination, documentPath, index);
    } on Object catch (error) {
      log.w('move the kept versions of $documentPath', error);
    }
  }

  /// A history already kept under the id a document is moving to belongs to
  /// whatever used to have that path: a chapter deleted from it, or one moved
  /// away. Ids are a hash of the path, so the two would otherwise braid into
  /// one list and a restore would offer one document's text as a version of
  /// another. The older history is set aside under a name of its own, whole
  /// and still readable, rather than added to or written over.
  ///
  /// Nothing is set aside until the move that needs the name can be made:
  /// the incoming history goes to a name beside it first, which is what
  /// proves the move is possible. Whatever fails, every step taken is put
  /// back, so both histories end up where they started.
  Future<void> _adoptOverOccupant(
    Directory source,
    Directory destination,
  ) async {
    final staged = '${destination.path}$_adoptingSuffix';
    await movePathNoReplace(source.path, staged);
    final aside =
        '${destination.path}$_supersededSuffix'
        '${_stamp(DateTime.now().toUtc())}';
    try {
      await movePathNoReplace(destination.path, aside);
    } on Object {
      await movePathNoReplace(staged, source.path);
      rethrow;
    }
    try {
      await movePathNoReplace(staged, destination.path);
    } on Object {
      await movePathNoReplace(aside, destination.path);
      await movePathNoReplace(staged, source.path);
      rethrow;
    }
    log.w('set aside the versions already kept at ${destination.path}');
  }

  /// The versions listed for [folder], repairing an index that is gone or
  /// that nothing can read.
  ///
  /// An index is a list of files that are on the disk anyway, so it can be
  /// written again from them. Letting a truncated one stand would instead
  /// fail every later save and delete of that document, for good.
  Future<_BackupIndex> _readIndex(Directory folder) async {
    final file = File(p.join(folder.path, _indexName));
    try {
      if (!await file.exists()) {
        return _BackupIndex.rebuilt(await _rebuilt(folder));
      }
      // Decoded here rather than by `readAsString`, which reports bytes
      // that are not UTF-8 as a [FileSystemException] and so would skip
      // the repair below.
      return _listed(utf8.decode(await file.readAsBytes()));
    } on FormatException catch (error) {
      log.e('read the kept versions in ${folder.path}', error);
      await _putAside(file);
      return _BackupIndex.rebuilt(await _rebuilt(folder));
    }
  }

  _BackupIndex _listed(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?> || json['versions'] is! List) {
      throw const FormatException('the kept versions are not a list');
    }
    final versions = json['versions']! as List;
    final listed = <BackupVersion>[];
    for (final version in versions) {
      if (version is! Map<String, Object?>) {
        throw const FormatException('a kept version is not an object');
      }
      listed.add(BackupVersion.fromJson(version));
    }
    return _BackupIndex(json, listed);
  }

  /// What the version files in [folder] say, oldest first.
  ///
  /// The order is by commit time and then by file name, so it is total: two
  /// versions committed in the same millisecond would otherwise come back in
  /// whatever order the directory listed them, and the newest of them decides
  /// what a save compares against and what a restore offers first.
  ///
  /// A version file whose bytes cannot be read is **left out of the index**,
  /// and logged. It stays on the disk, where it can still be recovered by
  /// hand, but nothing here can say when it was written or what it held.
  ///
  /// Only a whole version ever carries a version's name: a kept copy is
  /// staged under a name of its own and put in place with one rename, so what
  /// a write killed half way leaves behind is a staged copy, which [_isVersion]
  /// does not match, and never a truncated version listed as a real one.
  Future<List<BackupVersion>> _rebuilt(Directory folder) async {
    final versions = <BackupVersion>[];
    await for (final entry in directoryEntries(folder)) {
      if (entry is! File || !_isVersion(entry.path)) continue;
      final version = await _describe(entry);
      if (version != null) versions.add(version);
    }
    versions.sort(_byTimeThenName);
    return versions;
  }

  Future<BackupVersion?> _describe(File file) async {
    try {
      final bytes = versionBytes(await file.readAsBytes());
      final name = p.basename(file.path);
      return BackupVersion(
        file: name,
        time: _timeIn(name) ?? (await file.stat()).modified.toUtc(),
        size: bytes.length,
        hash: sha256.convert(bytes).toString(),
      );
    } on Object catch (error) {
      log.e('list the kept version ${file.path}', error);
      return null;
    }
  }

  Future<void> _putAside(File index) async {
    final aside =
        '${index.path}$_corruptSuffix'
        '${_stamp(DateTime.now().toUtc())}';
    try {
      await index.rename(aside);
      log.w('put the unreadable list of kept versions aside at $aside');
    } on FileSystemException catch (error) {
      log.w('put ${index.path} aside', error);
    }
  }

  Future<void> _writeIndex(
    Directory folder,
    String documentPath,
    _BackupIndex index, {
    BackupVersion? append,
  }) async {
    final json = {
      ...index.data,
      'path': documentPath,
      if (append != null)
        'versions': [...index.data['versions']! as List, append.toJson()],
    };
    await replaceFile(
      p.join(folder.path, _indexName),
      utf8.encode(jsonEncode(json)),
    );
  }
}

/// Validated known fields serve version lookup; the original objects retain
/// metadata this build does not interpret when appending or moving history.
final class _BackupIndex {
  const _BackupIndex(this.data, this.versions);

  _BackupIndex.rebuilt(List<BackupVersion> versions)
    : this({
        'versions': [for (final version in versions) version.toJson()],
      }, versions);

  final Map<String, Object?> data;
  final List<BackupVersion> versions;
}

const _indexName = 'index.json';

/// One kept version: the bytes of the document as they were.
const _versionSuffix = '.pgn';

/// What earlier builds named a kept version, which held the same bytes
/// gzipped.
const _compressedSuffix = '.pgn.gz';

bool _isVersion(String path) =>
    path.endsWith(_versionSuffix) || path.endsWith(_compressedSuffix);

/// The document a kept version file holds, whichever build kept it.
List<int> versionBytes(List<int> stored) =>
    stored.length >= 2 && stored[0] == 0x1f && stored[1] == 0x8b
    ? gzip.decode(stored)
    : stored;

/// What an index nobody could read, and a history the id it lived under now
/// belongs to another document, are renamed to. Both keep a commit stamp so
/// they never collide, and neither is ever read again by this code.
const _corruptSuffix = '.corrupt-';
const _supersededSuffix = '.superseded-';

/// Where an incoming history waits while the name it is taking is cleared.
/// One name per id, so a leftover from an interrupted adoption stops the next
/// one rather than being written over: both histories are then still whole,
/// each under its own id.
const _adoptingSuffix = '.adopting';

/// Commit time decides, and the file name breaks a tie; both are part of the
/// name a version was written under, so the order is the same on every run.
int _byTimeThenName(BackupVersion a, BackupVersion b) {
  final byTime = a.time.compareTo(b.time);
  return byTime != 0 ? byTime : a.file.compareTo(b.file);
}

/// The commit time a version file's name carries, or null when the name is
/// not one this app wrote. See [_stamp] for the spelling.
DateTime? _timeIn(String name) {
  final stamp = _stamped.firstMatch(name);
  if (stamp == null) return null;
  return DateTime.tryParse(
    '${stamp[1]}-${stamp[2]}-${stamp[3]}T'
    '${stamp[4]}:${stamp[5]}:${stamp[6]}.${stamp[7]}Z',
  );
}

final _stamped = RegExp(
  r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\d{3,6})Z-',
);

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

  /// Throws a [FormatException] on anything that is not a version this app
  /// wrote, so a damaged index is repaired rather than believed.
  factory BackupVersion.fromJson(Map<String, Object?> json) {
    final file = json['file'];
    final time = json['time'];
    final size = json['size'];
    final hash = json['hash'];
    if (file is! String || time is! String || size is! int || hash is! String) {
      throw const FormatException('a kept version is missing its fields');
    }
    return BackupVersion(
      file: file,
      time: DateTime.parse(time),
      size: size,
      hash: hash,
    );
  }

  final String file;
  final DateTime time;
  final int size;

  /// SHA-256 of the document's bytes.
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
