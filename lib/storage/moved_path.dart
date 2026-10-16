import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'operation_journal.dart';
import 'recovery_files.dart';
import 'relocation_record.dart';

/// The file or folder a relocation renames: at its old name before and its
/// new one after, known by its native identity.
sealed class MovedPath implements Pivot {
  MovedPath(
    this.record, {
    required this.documents,
    required this.synchronize,
    this.landed,
  });

  final RelocationRecord record;

  /// The canonical Documents folder.
  final Directory documents;
  final Future<void> Function(String) synchronize;

  /// Told once the new name is durable.
  final Future<void> Function()? landed;

  bool get _folder => this is MovedFolder;

  @override
  Set<String> get paths => {record.from, record.to};

  @override
  Future<Holds> look() async {
    try {
      if (canonicalRecoveryRoot(Directory(record.trainingRoot)).path !=
          documents.path) {
        return const HoldsOther('The recorded training root alias changed.');
      }
      await relocationParents(documents, record.from, create: false);
      await relocationParents(documents, record.to, create: false);
      final holds = await _holds();
      if (holds is! HoldsBefore) return holds;
      try {
        await _verifyBefore();
        await requireSameFileSystem(record.from, record.to, directory: _folder);
      } on FileSystemException catch (error) {
        // Its names show it has not moved; only what it holds is unreadable.
        return CannotTell('$error', unapplied: true);
      }
      return holds;
    } on RecoveryRequired catch (error) {
      return HoldsOther(error.detail);
    } on FileSystemException catch (error) {
      return CannotTell('$error');
    }
  }

  /// Where the name is now, by native identity alone.
  Future<Holds> _holds();

  /// Throws unless what is still at the old name is what was planned.
  Future<void> _verifyBefore() async {}

  Future<({int status, String? identity})> _observe(String path);

  @override
  Future<void> apply() async {
    final created = await relocationParents(documents, record.to, create: true);
    try {
      await movePathNoReplace(record.from, record.to);
    } on Object catch (error) {
      await _removeEmptyParents(created);
      if (error is NativeNameCollision) {
        throw PivotTaken('${record.to} was taken while the move waited.');
      }
      rethrow;
    }
  }

  /// A folder removed since the move (the old one, emptied by it, say) has
  /// no entry left to make durable: each side flushes from the nearest
  /// folder above it that is still there.
  @override
  Future<void> settle() async {
    for (final path in [record.from, record.to]) {
      await flushRecoveryAncestry(
        _existingAncestor(p.dirname(path), documents.path),
        through: documents.path,
        synchronize: synchronize,
      );
    }
    await landed?.call();
  }

  @override
  Future<bool> putBack() async {
    if (await look() is! HoldsAfter) return false;
    await movePathNoReplace(record.to, record.from);
    await flushRecoveryDirectory(
      p.dirname(record.from),
      synchronize: synchronize,
    );
    await flushRecoveryDirectory(
      p.dirname(record.to),
      synchronize: synchronize,
    );
    return true;
  }

  /// A refused native rename can leave private empty parents. Remove only
  /// directories this attempt created and still owns; intent remains retryable.
  Future<void> _removeEmptyParents(List<(String, String)> created) async {
    final source = (await _observe(record.from)).identity;
    final targetStatus = (await _observe(record.to)).status;
    if (source != record.identity || targetStatus != 1) return;
    for (final (path, identity) in created.reversed) {
      try {
        if ((await observeDirectory(path)).identity != identity) return;
        final directory = Directory(path);
        if (!await directoryEntries(directory, followLinks: false).isEmpty) {
          return;
        }
        await directory.delete();
        await flushRecoveryDirectory(p.dirname(path), synchronize: synchronize);
      } on FileSystemException {
        // Preserve anything now occupied or inaccessible. The original error
        // remains the command's outcome and its committing intent is retained.
        return;
      }
    }
  }
}

/// A PGN a move renames, known by its identity and its bytes.
final class MovedFile extends MovedPath {
  MovedFile(
    FileRelocationRecord super.record, {
    required super.documents,
    required super.synchronize,
    super.landed,
  });

  @override
  Future<({int status, String? identity})> _observe(String path) async {
    final observed = await observeFile(path);
    return (status: observed.status, identity: observed.identity);
  }

  @override
  Future<Holds> _holds() async {
    final file = record as FileRelocationRecord;
    final from = await observeFile(file.from);
    final to = await observeFile(file.to);
    requireObserved(from.status, file.from);
    requireObserved(to.status, file.to);
    bool owns(NativeFileObservation observed) =>
        observed.status == 0 &&
        observed.identity == file.identity &&
        observed.sha256Hex == file.hash;
    if (owns(from) && to.status == 1) return const HoldsBefore();
    if (from.status == 1 && owns(to)) return const HoldsAfter();
    return const HoldsOther('The recorded PGN location or identity changed.');
  }
}

/// A folder a move renames whole. Its whole tree is checked before it
/// moves; once moved it is the user's again, so edits inside it, or a
/// history offered back as a deleted chapter, never stop the rest of the
/// move from finishing.
final class MovedFolder extends MovedPath {
  MovedFolder(
    FolderRelocationRecord super.record, {
    required super.documents,
    required super.synchronize,
    super.landed,
  });

  @override
  Future<({int status, String? identity})> _observe(String path) =>
      observeDirectory(path).then(
        (observed) => (status: observed.status, identity: observed.identity),
      );

  @override
  Future<void> _verifyBefore() =>
      (record as FolderRelocationRecord).snapshot.verify(record.from);

  @override
  Future<Holds> _holds() async {
    final folder = record as FolderRelocationRecord;
    final from = await observeDirectory(folder.from);
    final to = await observeDirectory(folder.to);
    requireObserved(from.status, folder.from);
    requireObserved(to.status, folder.to);
    if (from.status == 0 &&
        from.identity == folder.identity &&
        to.status == 1) {
      return const HoldsBefore();
    }
    if (from.status == 1 && to.status == 0 && to.identity == folder.identity) {
      return const HoldsAfter();
    }
    return const HoldsOther(
      'The recorded folder location or identity changed.',
    );
  }
}

/// [directory], or the nearest folder above it up to [root] that exists.
String _existingAncestor(String directory, String root) {
  var current = directory;
  while (p.isWithin(root, current) &&
      FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.notFound) {
    current = p.dirname(current);
  }
  return current;
}

/// Probe every existing ancestor of [path] under [documents] without
/// following links. Missing parents are allowed while planning and looking,
/// and are created only when [create]; answers those it created.
Future<List<(String, String)>> relocationParents(
  Directory documents,
  String path, {
  required bool create,
}) async {
  if (!await recoveryDirectory(documents)) {
    throw const RecoveryRequired('The Documents directory is missing.');
  }
  final created = <(String, String)>[];
  var parent = documents.path;
  for (final part in p.split(p.relative(p.dirname(path), from: parent))) {
    if (part == '.') continue;
    parent = p.join(parent, part);
    if (await recoveryDirectory(Directory(parent))) continue;
    if (!create) return created;
    await recoveryDirectory(Directory(parent), create: true);
    created.add((parent, (await observeDirectory(parent)).identity!));
  }
  return created;
}
