// The File and RandomAccessFile a FaultyDisk run hands out. Each reading or
// mutating member is one traced effect on the real entity; the rest
// delegate. close and unlock always really run: a killed process loses its
// handles too, and a leaked one would block deletes on Windows.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fault_plan.dart';
import 'faulty_disk.dart';
import 'io_trace.dart';
import 'traced_directory.dart';

final class TracedFile implements File {
  TracedFile(this._disk, this.path) : _real = _disk.real(() => File(path));

  final DiskSession _disk;
  final File _real;

  @override
  final String path;

  Future<R> _io<R>(
    IoKind kind,
    String message,
    Future<R> Function() call, {
    String? to,
    Future<void> Function()? midway,
  }) => _disk.effect(
    kind,
    path,
    call,
    to: to,
    midway: midway,
    failed: (error) => throw fileSystemFailure(error, message, path),
  );

  R _ioSync<R>(
    IoKind kind,
    String message,
    R Function() call, {
    String? to,
    void Function()? midway,
  }) => _disk.effectSync(
    kind,
    path,
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
  File get absolute => TracedFile(_disk, _real.absolute.path);

  @override
  Directory get parent => TracedDirectory(_disk, _real.parent.path);

  @override
  Future<bool> exists() => _disk.effect(
    IoKind.stat,
    path,
    _real.exists,
    failed: (error) => error == IoError.spuriousMissing
        ? false
        : throw fileSystemFailure(error, 'Cannot check existence', path),
  );

  @override
  bool existsSync() => _disk.effectSync(
    IoKind.stat,
    path,
    _real.existsSync,
    failed: (error) => error == IoError.spuriousMissing
        ? false
        : throw fileSystemFailure(error, 'Cannot check existence', path),
  );

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await _io(
      IoKind.create,
      'Cannot create file',
      () => _real.create(recursive: recursive, exclusive: exclusive),
    );
    return this;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) => _ioSync(
    IoKind.create,
    'Cannot create file',
    () => _real.createSync(recursive: recursive, exclusive: exclusive),
  );

  @override
  Future<File> rename(String newPath) async {
    final moved = await _io(
      IoKind.rename,
      "Cannot rename file to '$newPath'",
      () => _real.rename(newPath),
      to: newPath,
    );
    return TracedFile(_disk, moved.path);
  }

  @override
  File renameSync(String newPath) {
    final moved = _ioSync(
      IoKind.rename,
      "Cannot rename file to '$newPath'",
      () => _real.renameSync(newPath),
      to: newPath,
    );
    return TracedFile(_disk, moved.path);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _io(
      IoKind.delete,
      'Cannot delete file',
      () => _real.delete(recursive: recursive),
    );
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) => _ioSync(
    IoKind.delete,
    'Cannot delete file',
    () => _real.deleteSync(recursive: recursive),
  );

  @override
  Future<File> copy(String newPath) async {
    final copied = await _io(
      IoKind.copy,
      "Cannot copy file to '$newPath'",
      () => _real.copy(newPath),
      to: newPath,
    );
    return TracedFile(_disk, copied.path);
  }

  @override
  File copySync(String newPath) {
    final copied = _ioSync(
      IoKind.copy,
      "Cannot copy file to '$newPath'",
      () => _real.copySync(newPath),
      to: newPath,
    );
    return TracedFile(_disk, copied.path);
  }

  @override
  Future<int> length() =>
      _io(IoKind.stat, 'Cannot retrieve length of file', _real.length);

  @override
  int lengthSync() =>
      _ioSync(IoKind.stat, 'Cannot retrieve length of file', _real.lengthSync);

  @override
  Future<DateTime> lastAccessed() =>
      _io(IoKind.stat, 'Cannot retrieve access time', _real.lastAccessed);

  @override
  DateTime lastAccessedSync() => _ioSync(
    IoKind.stat,
    'Cannot retrieve access time',
    _real.lastAccessedSync,
  );

  @override
  Future<void> setLastAccessed(DateTime time) => _io(
    IoKind.write,
    'Failed to set file access time',
    () => _real.setLastAccessed(time),
  );

  @override
  void setLastAccessedSync(DateTime time) => _ioSync(
    IoKind.write,
    'Failed to set file access time',
    () => _real.setLastAccessedSync(time),
  );

  @override
  Future<DateTime> lastModified() =>
      _io(IoKind.stat, 'Cannot retrieve modification time', _real.lastModified);

  @override
  DateTime lastModifiedSync() => _ioSync(
    IoKind.stat,
    'Cannot retrieve modification time',
    _real.lastModifiedSync,
  );

  @override
  Future<void> setLastModified(DateTime time) => _io(
    IoKind.write,
    'Failed to set file modification time',
    () => _real.setLastModified(time),
  );

  @override
  void setLastModifiedSync(DateTime time) => _ioSync(
    IoKind.write,
    'Failed to set file modification time',
    () => _real.setLastModifiedSync(time),
  );

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final kind = mode == FileMode.read ? IoKind.read : IoKind.create;
    final handle = await _io(
      kind,
      'Cannot open file',
      () => _real.open(mode: mode),
    );
    return TracedRandomAccessFile(_disk, handle);
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    final kind = mode == FileMode.read ? IoKind.read : IoKind.create;
    final handle = _ioSync(
      kind,
      'Cannot open file',
      () => _real.openSync(mode: mode),
    );
    return TracedRandomAccessFile(_disk, handle);
  }

  /// One read when listened to; the stream itself is the real file's.
  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    final out = StreamController<List<int>>();
    out.onListen = () async {
      try {
        await _io(IoKind.read, 'Cannot open file', () async {});
        await _disk.real(() => out.addStream(_real.openRead(start, end)));
      } on Object catch (error, stack) {
        out.addError(error, stack);
      }
      await out.close();
    };
    return out.stream;
  }

  /// One write when opened; what goes through the sink is that same effect,
  /// and none of it reaches a frozen disk.
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => _ioSync(
    IoKind.write,
    'Cannot open file',
    () => IOSink(_FrozenAwareFile(_disk, _real, mode), encoding: encoding),
  );

  @override
  Future<Uint8List> readAsBytes() =>
      _io(IoKind.read, 'Cannot open file', _real.readAsBytes);

  @override
  Uint8List readAsBytesSync() =>
      _ioSync(IoKind.read, 'Cannot open file', _real.readAsBytesSync);

  @override
  Future<String> readAsString({Encoding encoding = utf8}) => _io(
    IoKind.read,
    'Cannot open file',
    () => _real.readAsString(encoding: encoding),
  );

  @override
  String readAsStringSync({Encoding encoding = utf8}) => _ioSync(
    IoKind.read,
    'Cannot open file',
    () => _real.readAsStringSync(encoding: encoding),
  );

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) => _io(
    IoKind.read,
    'Cannot open file',
    () => _real.readAsLines(encoding: encoding),
  );

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) => _ioSync(
    IoKind.read,
    'Cannot open file',
    () => _real.readAsLinesSync(encoding: encoding),
  );

  /// Midway leaves the first half of [bytes]: a torn write.
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await _io(
      IoKind.write,
      'Cannot open file',
      () => _real.writeAsBytes(bytes, mode: mode, flush: flush),
      midway: () => _real.writeAsBytes(_torn(bytes), mode: mode),
    );
    return this;
  }

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => _ioSync(
    IoKind.write,
    'Cannot open file',
    () => _real.writeAsBytesSync(bytes, mode: mode, flush: flush),
    midway: () => _real.writeAsBytesSync(_torn(bytes), mode: mode),
  );

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => writeAsBytesSync(encoding.encode(contents), mode: mode, flush: flush);

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

/// What openWrite's sink writes through: dart:io's own file consumer, except
/// that the file is opened and each chunk written only while the disk is
/// not frozen. The handle is always really closed.
final class _FrozenAwareFile implements StreamConsumer<List<int>> {
  _FrozenAwareFile(this._disk, this._file, this._mode);

  final DiskSession _disk;
  final File _file;
  final FileMode _mode;
  RandomAccessFile? _handle;
  var _closed = false;

  Future<RandomAccessFile> _open() async {
    if (_handle case final handle?) return handle;
    _disk.guard(_file.path);
    return _handle = await _file.open(mode: _mode);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    try {
      final handle = await _open();
      await for (final chunk in stream) {
        _disk.guard(_file.path);
        await handle.writeFrom(chunk);
      }
    } on Object {
      _closed = true;
      await _handle?.close();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final handle = _handle ?? await _open();
    await handle.close();
  }
}

/// An open file whose reads and writes are traced against its path.
final class TracedRandomAccessFile implements RandomAccessFile {
  TracedRandomAccessFile(this._disk, this._real);

  final DiskSession _disk;
  final RandomAccessFile _real;

  @override
  String get path => _real.path;

  Future<R> _io<R>(
    IoKind kind,
    Future<R> Function() call, {
    Future<void> Function()? midway,
  }) => _disk.effect(
    kind,
    path,
    call,
    midway: midway,
    failed: (error) => throw fileSystemFailure(error, _message(kind), path),
  );

  R _ioSync<R>(IoKind kind, R Function() call, {void Function()? midway}) =>
      _disk.effectSync(
        kind,
        path,
        call,
        midway: midway,
        failed: (error) => throw fileSystemFailure(error, _message(kind), path),
      );

  static String _message(IoKind kind) => switch (kind) {
    IoKind.read => 'readInto failed',
    IoKind.sync => 'flush failed',
    _ => 'writeFrom failed',
  };

  @override
  Future<void> close() => _real.close();

  @override
  void closeSync() => _real.closeSync();

  @override
  Future<int> readByte() => _io(IoKind.read, _real.readByte);

  @override
  int readByteSync() => _ioSync(IoKind.read, _real.readByteSync);

  @override
  Future<Uint8List> read(int count) =>
      _io(IoKind.read, () => _real.read(count));

  @override
  Uint8List readSync(int count) =>
      _ioSync(IoKind.read, () => _real.readSync(count));

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) =>
      _io(IoKind.read, () => _real.readInto(buffer, start, end));

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) =>
      _ioSync(IoKind.read, () => _real.readIntoSync(buffer, start, end));

  @override
  Future<RandomAccessFile> writeByte(int value) async {
    await _io(IoKind.write, () => _real.writeByte(value));
    return this;
  }

  @override
  int writeByteSync(int value) =>
      _ioSync(IoKind.write, () => _real.writeByteSync(value));

  /// Midway leaves the first half of the range: a torn write.
  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final stop = end ?? buffer.length;
    await _io(
      IoKind.write,
      () => _real.writeFrom(buffer, start, stop),
      midway: () => _real.writeFrom(buffer, start, start + (stop - start) ~/ 2),
    );
    return this;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    final stop = end ?? buffer.length;
    _ioSync(
      IoKind.write,
      () => _real.writeFromSync(buffer, start, stop),
      midway: () =>
          _real.writeFromSync(buffer, start, start + (stop - start) ~/ 2),
    );
  }

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) => writeFrom(encoding.encode(string));

  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) =>
      writeFromSync(encoding.encode(string));

  @override
  Future<int> position() => _real.position();

  @override
  int positionSync() => _real.positionSync();

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _real.setPosition(position);
    return this;
  }

  @override
  void setPositionSync(int position) => _real.setPositionSync(position);

  @override
  Future<RandomAccessFile> truncate(int length) async {
    await _io(IoKind.write, () => _real.truncate(length));
    return this;
  }

  @override
  void truncateSync(int length) =>
      _ioSync(IoKind.write, () => _real.truncateSync(length));

  @override
  Future<int> length() => _real.length();

  @override
  int lengthSync() => _real.lengthSync();

  @override
  Future<RandomAccessFile> flush() async {
    await _io(IoKind.sync, _real.flush);
    return this;
  }

  @override
  void flushSync() => _ioSync(IoKind.sync, _real.flushSync);

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    await _real.lock(mode, start, end);
    return this;
  }

  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) => _real.lockSync(mode, start, end);

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async {
    await _real.unlock(start, end);
    return this;
  }

  @override
  void unlockSync([int start = 0, int end = -1]) =>
      _real.unlockSync(start, end);

  @override
  String toString() => _real.toString();
}

List<int> _torn(List<int> bytes) => bytes.sublist(0, bytes.length ~/ 2);

/// What `stat` answers for a path it cannot see.
final class MissingStat implements FileStat {
  const MissingStat();

  static final _never = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  DateTime get changed => _never;

  @override
  DateTime get modified => _never;

  @override
  DateTime get accessed => _never;

  @override
  FileSystemEntityType get type => FileSystemEntityType.notFound;

  @override
  int get mode => 0;

  @override
  int get size => -1;

  @override
  String modeString() => '---------';
}
