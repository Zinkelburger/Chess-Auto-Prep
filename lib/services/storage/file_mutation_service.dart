/// The only general-purpose boundary for destructive filesystem operations.
library;

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../utils/file_operation_lock.dart';

class UnsafeFileMutation implements IOException {
  const UnsafeFileMutation(this.message);

  final String message;

  @override
  String toString() => 'UnsafeFileMutation: $message';
}

/// Result of a recoverable deletion. [quarantinedPath] remains on disk until a
/// future explicit purge policy removes it.
class QuarantineReceipt {
  const QuarantineReceipt({
    required this.originalPath,
    required this.quarantinedPath,
  });

  final String originalPath;
  final String quarantinedPath;
}

class FileMutationService {
  FileMutationService();

  static final FileMutationService instance = FileMutationService();

  Future<void> createDirectoryNoReplace(
    Directory destination, {
    required Directory allowedRoot,
  }) async {
    await withFileOperationLock(allowedRoot.path, () async {
      await _requireSafeDestination(destination, allowedRoot: allowedRoot);
      if (await _entityExists(destination.path)) {
        throw FileSystemException(
          'Destination already exists; refusing to reuse it',
          destination.path,
        );
      }
      await destination.create();
    });
  }

  /// Moves a managed file into [quarantineRoot]. Neither the managed root nor
  /// a symlink may be deleted, and the resolved path must remain under
  /// [allowedRoot].
  Future<QuarantineReceipt?> quarantineFile(
    File target, {
    required Directory allowedRoot,
    required Directory quarantineRoot,
    Directory? quarantineAllowedRoot,
  }) async {
    if (!await target.exists()) return null;
    return withFileOperationLock(target.parent.path, () async {
      if (!await target.exists()) return null;
      await _requireSafeTarget(target, allowedRoot: allowedRoot);
      final trashRoot = quarantineAllowedRoot ?? allowedRoot;
      await _requireSafeDirectoryTree(quarantineRoot, allowedRoot: trashRoot);
      await quarantineRoot.create(recursive: true);
      await _requireSafeTarget(quarantineRoot, allowedRoot: trashRoot);
      final destination = File(
        p.join(quarantineRoot.path, _quarantineName(p.basename(target.path))),
      );
      if (await _entityExists(destination.path)) {
        throw FileSystemException(
          'Quarantine destination already exists',
          destination.path,
        );
      }
      await target.rename(destination.path);
      return QuarantineReceipt(
        originalPath: target.path,
        quarantinedPath: destination.path,
      );
    });
  }

  /// Moves a managed directory into [quarantineRoot] without traversing it.
  Future<QuarantineReceipt?> quarantineDirectory(
    Directory target, {
    required Directory allowedRoot,
    required Directory quarantineRoot,
    Directory? quarantineAllowedRoot,
  }) async {
    if (!await target.exists()) return null;
    return withFileOperationLock(target.parent.path, () async {
      if (!await target.exists()) return null;
      await _requireSafeTarget(target, allowedRoot: allowedRoot);
      final trashRoot = quarantineAllowedRoot ?? allowedRoot;
      await _requireSafeDirectoryTree(quarantineRoot, allowedRoot: trashRoot);
      await quarantineRoot.create(recursive: true);
      await _requireSafeTarget(quarantineRoot, allowedRoot: trashRoot);
      final destination = Directory(
        p.join(quarantineRoot.path, _quarantineName(p.basename(target.path))),
      );
      if (await _entityExists(destination.path)) {
        throw FileSystemException(
          'Quarantine destination already exists',
          destination.path,
        );
      }
      await target.rename(destination.path);
      return QuarantineReceipt(
        originalPath: target.path,
        quarantinedPath: destination.path,
      );
    });
  }

  /// Permanently removes disposable support/cache data. User documents should
  /// use a quarantine method instead.
  Future<void> deleteDisposableFile(
    File target, {
    required Directory allowedRoot,
  }) async {
    if (!await target.exists()) return;
    await withFileOperationLock(target.parent.path, () async {
      if (!await target.exists()) return;
      await _requireSafeTarget(target, allowedRoot: allowedRoot);
      await target.delete();
    });
  }

  Future<void> deleteDisposableDirectory(
    Directory target, {
    required Directory allowedRoot,
  }) async {
    if (!await target.exists()) return;
    await withFileOperationLock(target.parent.path, () async {
      if (!await target.exists()) return;
      await _requireSafeTarget(target, allowedRoot: allowedRoot);
      await target.delete(recursive: true);
    });
  }

  /// Moves a file without overwrite. Both paths must resolve inside
  /// [allowedRoot], and links are rejected at the mutation boundary.
  Future<void> moveFileNoReplace(
    File source,
    File destination, {
    required Directory allowedRoot,
  }) async {
    await withFileOperationLock(allowedRoot.path, () async {
      await _requireSafeTarget(source, allowedRoot: allowedRoot);
      await _requireSafeDestination(destination, allowedRoot: allowedRoot);
      if (!await source.exists()) {
        throw FileSystemException('Source file does not exist', source.path);
      }
      if (await _entityExists(destination.path)) {
        throw FileSystemException(
          'Destination already exists; refusing to overwrite',
          destination.path,
        );
      }
      await source.rename(destination.path);
    });
  }

  Future<void> moveDirectoryNoReplace(
    Directory source,
    Directory destination, {
    required Directory allowedRoot,
  }) async {
    if (p.equals(source.path, destination.path)) return;
    if (p.isWithin(source.path, destination.path)) {
      throw const UnsafeFileMutation(
        'A directory cannot be moved into itself.',
      );
    }
    await withFileOperationLock(allowedRoot.path, () async {
      await _requireSafeTarget(source, allowedRoot: allowedRoot);
      await _requireSafeDestination(destination, allowedRoot: allowedRoot);
      if (!await source.exists()) {
        throw FileSystemException(
          'Source directory does not exist',
          source.path,
        );
      }
      if (await _entityExists(destination.path)) {
        throw FileSystemException(
          'Destination already exists; refusing to overwrite',
          destination.path,
        );
      }
      await source.rename(destination.path);
    });
  }

  Future<void> _requireSafeTarget(
    FileSystemEntity target, {
    required Directory allowedRoot,
  }) async {
    final root = await _rootPaths(allowedRoot);
    final lexical = p.normalize(p.absolute(target.path));
    if (p.equals(root.lexical, lexical) || !p.isWithin(root.lexical, lexical)) {
      throw UnsafeFileMutation(
        'Refusing to mutate ${target.path}: it is outside the allowed root.',
      );
    }
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw UnsafeFileMutation(
        'Refusing to mutate ${target.path}: symbolic links are not managed data.',
      );
    }
    if (type != FileSystemEntityType.notFound) {
      final resolved = p.normalize(await target.resolveSymbolicLinks());
      if (!p.isWithin(root.canonical, resolved)) {
        throw UnsafeFileMutation(
          'Refusing to mutate ${target.path}: its resolved path escapes the root.',
        );
      }
    }
  }

  Future<void> _requireSafeDestination(
    FileSystemEntity destination, {
    required Directory allowedRoot,
  }) async {
    final root = await _rootPaths(allowedRoot);
    final lexical = p.normalize(p.absolute(destination.path));
    if (p.equals(root.lexical, lexical) || !p.isWithin(root.lexical, lexical)) {
      throw UnsafeFileMutation(
        'Refusing destination ${destination.path}: it is outside the root.',
      );
    }
    final parent = Directory(p.dirname(lexical));
    if (!await parent.exists()) {
      throw FileSystemException(
        'Destination parent does not exist',
        parent.path,
      );
    }
    final resolvedParent = p.normalize(await parent.resolveSymbolicLinks());
    if (!p.equals(root.canonical, resolvedParent) &&
        !p.isWithin(root.canonical, resolvedParent)) {
      throw UnsafeFileMutation(
        'Refusing destination ${destination.path}: its parent escapes the root.',
      );
    }
  }

  /// Validates a directory that may not exist yet. Every existing component
  /// below [allowedRoot] must be a real directory (never a link), preventing a
  /// recursive create from being redirected outside the managed tree.
  Future<void> _requireSafeDirectoryTree(
    Directory destination, {
    required Directory allowedRoot,
  }) async {
    final root = await _rootPaths(allowedRoot);
    final lexical = p.normalize(p.absolute(destination.path));
    if (p.equals(root.lexical, lexical) || !p.isWithin(root.lexical, lexical)) {
      throw UnsafeFileMutation(
        'Refusing directory ${destination.path}: it is outside the root.',
      );
    }
    var current = root.lexical;
    for (final component in p.split(p.relative(lexical, from: root.lexical))) {
      current = p.join(current, component);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.link) {
        throw UnsafeFileMutation(
          'Refusing directory ${destination.path}: $current is a link.',
        );
      }
      if (type != FileSystemEntityType.directory) {
        throw UnsafeFileMutation(
          'Refusing directory ${destination.path}: $current is not a directory.',
        );
      }
      final resolved = p.normalize(
        await Directory(current).resolveSymbolicLinks(),
      );
      if (!p.isWithin(root.canonical, resolved)) {
        throw UnsafeFileMutation(
          'Refusing directory ${destination.path}: $current escapes the root.',
        );
      }
    }
  }

  Future<({String lexical, String canonical})> _rootPaths(
    Directory directory,
  ) async {
    if (!await directory.exists()) {
      throw FileSystemException('Allowed root does not exist', directory.path);
    }
    return (
      lexical: p.normalize(p.absolute(directory.path)),
      canonical: p.normalize(await directory.resolveSymbolicLinks()),
    );
  }

  Future<bool> _entityExists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  String _quarantineName(String basename) {
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    return '${DateTime.now().microsecondsSinceEpoch}-$random-$basename';
  }
}
