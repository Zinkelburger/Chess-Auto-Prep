// The Directory and Link a FaultyDisk run hands out, and the IOOverrides
// that hands out every traced entity. What a traced entity returns (a
// renamed entity, a listing, a temporary folder) is traced too, so a
// journal record recovery lists and then quarantines is seen whole.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fault_plan.dart';
import 'faulty_disk.dart';
import 'io_trace.dart';
import 'traced_file.dart';

final class TracingOverrides extends IOOverrides {
  TracingOverrides(this._disk);

  final DiskSession _disk;

  @override
  File createFile(String path) => TracedFile(_disk, path);

  @override
  Directory createDirectory(String path) => TracedDirectory(_disk, path);

  @override
  Link createLink(String path) => TracedLink(_disk, path);

  @override
  Future<FileStat> stat(String path) => _disk.effect(
    IoKind.stat,
    path,
    () => super.stat(path),
    failed: (_) => const MissingStat(),
  );

  @override
  FileStat statSync(String path) => _disk.effectSync(
    IoKind.stat,
    path,
    () => super.statSync(path),
    failed: (_) => const MissingStat(),
  );

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      _disk.effect(
        IoKind.stat,
        path,
        () => super.fseGetType(path, followLinks),
        failed: (error) => _typeFailure(error, path),
      );

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      _disk.effectSync(
        IoKind.stat,
        path,
        () => super.fseGetTypeSync(path, followLinks),
        failed: (error) => _typeFailure(error, path),
      );

  @override
  Future<bool> fseIdentical(String path1, String path2) => _disk.effect(
    IoKind.stat,
    path1,
    () => super.fseIdentical(path1, path2),
    to: path2,
    failed: (error) =>
        throw fileSystemFailure(error, 'Error in identical', path1),
  );

  @override
  bool fseIdenticalSync(String path1, String path2) => _disk.effectSync(
    IoKind.stat,
    path1,
    () => super.fseIdenticalSync(path1, path2),
    to: path2,
    failed: (error) =>
        throw fileSystemFailure(error, 'Error in identical', path1),
  );
}

/// A missing path is `notFound`, as dart:io answers; anything else throws.
FileSystemEntityType _typeFailure(IoError error, String path) =>
    error == IoError.spuriousMissing
    ? FileSystemEntityType.notFound
    : throw fileSystemFailure(error, 'Error getting type', path);

/// [entity] as the traced entity of its kind.
FileSystemEntity traced(DiskSession disk, FileSystemEntity entity) =>
    switch (entity) {
      Directory() => TracedDirectory(disk, entity.path),
      Link() => TracedLink(disk, entity.path),
      _ => TracedFile(disk, entity.path),
    };

final class TracedDirectory implements Directory {
  TracedDirectory(this._disk, this.path)
    : _real = _disk.real(() => Directory(path));

  final DiskSession _disk;
  final Directory _real;

  @override
  final String path;

  Future<R> _io<R>(
    IoKind kind,
    String message,
    Future<R> Function() call, {
    String? at,
    String? to,
    Future<void> Function()? midway,
  }) => _disk.effect(
    kind,
    at ?? path,
    call,
    to: to,
    midway: midway,
    failed: (error) => throw fileSystemFailure(error, message, path),
  );

  R _ioSync<R>(
    IoKind kind,
    String message,
    R Function() call, {
    String? at,
    String? to,
    void Function()? midway,
  }) => _disk.effectSync(
    kind,
    at ?? path,
    call,
    to: to,
    midway: midway,
    failed: (error) => throw fileSystemFailure(error, message, path),
  );

  @override
  Uri get uri => _real.uri;

  @override
  bool get isAbsolute => _real.isAbsolute;

  @override
  Directory get absolute => TracedDirectory(_disk, _real.absolute.path);

  @override
  Directory get parent => TracedDirectory(_disk, _real.parent.path);

  @override
  Future<bool> exists() => _disk.effect(
    IoKind.stat,
    path,
    _real.exists,
    failed: (error) => error == IoError.spuriousMissing
        ? false
        : throw fileSystemFailure(error, 'Exists failed', path),
  );

  @override
  bool existsSync() => _disk.effectSync(
    IoKind.stat,
    path,
    _real.existsSync,
    failed: (error) => error == IoError.spuriousMissing
        ? false
        : throw fileSystemFailure(error, 'Exists failed', path),
  );

  /// Midway on a recursive create makes only the first missing parent.
  @override
  Future<Directory> create({bool recursive = false}) async {
    await _io(
      IoKind.mkdir,
      'Creation failed',
      () => _real.create(recursive: recursive),
      midway: recursive ? () async => _firstMissing()?.createSync() : null,
    );
    return this;
  }

  @override
  void createSync({bool recursive = false}) => _ioSync(
    IoKind.mkdir,
    'Creation failed',
    () => _real.createSync(recursive: recursive),
    midway: recursive ? () => _firstMissing()?.createSync() : null,
  );

  /// The outermost missing folder on the way to this one, when there are
  /// at least two, so creating it alone leaves the create unfinished.
  Directory? _firstMissing() {
    final missing = <String>[];
    for (var at = p.normalize(p.absolute(path)); ; at = p.dirname(at)) {
      if (Directory(at).existsSync() || p.dirname(at) == at) break;
      missing.add(at);
    }
    return missing.length < 2 ? null : Directory(missing.last);
  }

  /// Traced by its prefix; the OS picks the rest of the name.
  @override
  Future<Directory> createTemp([String? prefix]) async {
    final made = await _io(
      IoKind.mkdir,
      'Creation of temporary directory failed',
      () => _real.createTemp(prefix),
      at: p.join(path, '${prefix ?? ''}*'),
    );
    return TracedDirectory(_disk, made.path);
  }

  @override
  Directory createTempSync([String? prefix]) {
    final made = _ioSync(
      IoKind.mkdir,
      'Creation of temporary directory failed',
      () => _real.createTempSync(prefix),
      at: p.join(path, '${prefix ?? ''}*'),
    );
    return TracedDirectory(_disk, made.path);
  }

  @override
  Future<Directory> rename(String newPath) async {
    final moved = await _io(
      IoKind.rename,
      'Rename failed',
      () => _real.rename(newPath),
      to: newPath,
    );
    return TracedDirectory(_disk, moved.path);
  }

  @override
  Directory renameSync(String newPath) {
    final moved = _ioSync(
      IoKind.rename,
      'Rename failed',
      () => _real.renameSync(newPath),
      to: newPath,
    );
    return TracedDirectory(_disk, moved.path);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _io(
      IoKind.delete,
      'Deletion failed',
      () => _real.delete(recursive: recursive),
    );
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) => _ioSync(
    IoKind.delete,
    'Deletion failed',
    () => _real.deleteSync(recursive: recursive),
  );

  /// One read of the whole listing, then its entries as traced entities.
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    final entries = await _io(
      IoKind.list,
      'Directory listing failed',
      () => _real.list(recursive: recursive, followLinks: followLinks).toList(),
    );
    for (final entry in entries) {
      yield traced(_disk, entry);
    }
  }

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => [
    for (final entry in _ioSync(
      IoKind.list,
      'Directory listing failed',
      () => _real.listSync(recursive: recursive, followLinks: followLinks),
    ))
      traced(_disk, entry),
  ];

  @override
  Future<String> resolveSymbolicLinks() => _io(
    IoKind.stat,
    'Cannot resolve symbolic links',
    _real.resolveSymbolicLinks,
  );

  @override
  String resolveSymbolicLinksSync() => _ioSync(
    IoKind.stat,
    'Cannot resolve symbolic links',
    _real.resolveSymbolicLinksSync,
  );

  @override
  Future<FileStat> stat() => _disk.effect(
    IoKind.stat,
    path,
    _real.stat,
    failed: (_) => const MissingStat(),
  );

  @override
  FileStat statSync() => _disk.effectSync(
    IoKind.stat,
    path,
    _real.statSync,
    failed: (_) => const MissingStat(),
  );

  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) => _real.watch(events: events, recursive: recursive);

  @override
  String toString() => _real.toString();
}

final class TracedLink implements Link {
  TracedLink(this._disk, this.path) : _real = _disk.real(() => Link(path));

  final DiskSession _disk;
  final Link _real;

  @override
  final String path;

  Future<R> _io<R>(
    IoKind kind,
    String message,
    Future<R> Function() call, {
    String? to,
  }) => _disk.effect(
    kind,
    path,
    call,
    to: to,
    failed: (error) => throw fileSystemFailure(error, message, path),
  );

  R _ioSync<R>(IoKind kind, String message, R Function() call, {String? to}) =>
      _disk.effectSync(
        kind,
        path,
        call,
        to: to,
        failed: (error) => throw fileSystemFailure(error, message, path),
      );

  @override
  Uri get uri => _real.uri;

  @override
  bool get isAbsolute => _real.isAbsolute;

  @override
  Link get absolute => TracedLink(_disk, _real.absolute.path);

  @override
  Directory get parent => TracedDirectory(_disk, _real.parent.path);

  @override
  Future<bool> exists() => _disk.effect(
    IoKind.stat,
    path,
    _real.exists,
    failed: (error) => error == IoError.spuriousMissing
        ? false
        : throw fileSystemFailure(error, 'Exists failed', path),
  );

  @override
  bool existsSync() => _disk.effectSync(
    IoKind.stat,
    path,
    _real.existsSync,
    failed: (error) => error == IoError.spuriousMissing
        ? false
        : throw fileSystemFailure(error, 'Exists failed', path),
  );

  @override
  Future<Link> create(String target, {bool recursive = false}) async {
    await _io(
      IoKind.link,
      'Cannot create link',
      () => _real.create(target, recursive: recursive),
    );
    return this;
  }

  @override
  void createSync(String target, {bool recursive = false}) => _ioSync(
    IoKind.link,
    'Cannot create link',
    () => _real.createSync(target, recursive: recursive),
  );

  @override
  Future<Link> update(String target) async {
    await _io(IoKind.link, 'Cannot update link', () => _real.update(target));
    return this;
  }

  @override
  void updateSync(String target) => _ioSync(
    IoKind.link,
    'Cannot update link',
    () => _real.updateSync(target),
  );

  @override
  Future<Link> rename(String newPath) async {
    final moved = await _io(
      IoKind.rename,
      "Cannot rename link to '$newPath'",
      () => _real.rename(newPath),
      to: newPath,
    );
    return TracedLink(_disk, moved.path);
  }

  @override
  Link renameSync(String newPath) {
    final moved = _ioSync(
      IoKind.rename,
      "Cannot rename link to '$newPath'",
      () => _real.renameSync(newPath),
      to: newPath,
    );
    return TracedLink(_disk, moved.path);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _io(
      IoKind.delete,
      'Cannot delete link',
      () => _real.delete(recursive: recursive),
    );
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) => _ioSync(
    IoKind.delete,
    'Cannot delete link',
    () => _real.deleteSync(recursive: recursive),
  );

  @override
  Future<String> target() =>
      _io(IoKind.read, 'Cannot get target of link', _real.target);

  @override
  String targetSync() =>
      _ioSync(IoKind.read, 'Cannot get target of link', _real.targetSync);

  @override
  Future<String> resolveSymbolicLinks() => _io(
    IoKind.stat,
    'Cannot resolve symbolic links',
    _real.resolveSymbolicLinks,
  );

  @override
  String resolveSymbolicLinksSync() => _ioSync(
    IoKind.stat,
    'Cannot resolve symbolic links',
    _real.resolveSymbolicLinksSync,
  );

  @override
  Future<FileStat> stat() => _disk.effect(
    IoKind.stat,
    path,
    _real.stat,
    failed: (_) => const MissingStat(),
  );

  @override
  FileStat statSync() => _disk.effectSync(
    IoKind.stat,
    path,
    _real.statSync,
    failed: (_) => const MissingStat(),
  );

  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) => _real.watch(events: events, recursive: recursive);

  @override
  String toString() => _real.toString();
}
