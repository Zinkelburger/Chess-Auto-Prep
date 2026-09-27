import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';

final class _Snapshot extends Struct {
  @Uint64()
  external int volume;
  @Uint64()
  external int low;
  @Uint64()
  external int high;
  @Uint64()
  external int size;
  external Pointer<Uint8> bytes;
  @Int32()
  external int status;
  @Int32()
  external int error;
}

@Native<Pointer<_Snapshot> Function(Pointer<Utf8>)>(symbol: 'cap_snapshot_read')
external Pointer<_Snapshot> _read(Pointer<Utf8> path);
@Native<Pointer<_Snapshot> Function(Pointer<Utf8>)>(
  symbol: 'cap_directory_identity',
)
external Pointer<_Snapshot> _directoryIdentity(Pointer<Utf8> path);
@Native<Void Function(Pointer<_Snapshot>)>(symbol: 'cap_snapshot_free')
external void _free(Pointer<_Snapshot> value);
@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>(symbol: 'cap_install_new')
external int _installNew(Pointer<Utf8> from, Pointer<Utf8> to);
@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'cap_move_directory_new',
)
external int _movePathNoReplace(Pointer<Utf8> from, Pointer<Utf8> to);
@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'cap_sync_directory')
external int _syncDirectory(Pointer<Utf8> path);
@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'cap_sync_file')
external int _syncFile(Pointer<Utf8> path);
@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'cap_replace_file',
)
external int _replaceFile(
  Pointer<Utf8> from,
  Pointer<Utf8> to,
  Pointer<Utf8> backup,
);

/// Publishes a staged file. Windows preserves destination metadata with
/// ReplaceFileW; a missing destination is created without replacing a racer.
/// Antivirus and indexer handles may deny sharing briefly. Retry only those
/// errors, leaving the old file in place throughout the wait.
Future<void> replaceFileContents(String source, String destination) async {
  _checkPath(source);
  _checkPath(destination);
  final baseline = Platform.isWindows ? await observeFile(destination) : null;
  if (baseline != null && baseline.status != 0 && baseline.status != 1) {
    throw FileSystemException(
      'Cannot safely observe the replacement destination',
      destination,
    );
  }
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  final recovery =
      '$source.previous-$pid-${DateTime.now().microsecondsSinceEpoch}';
  while (true) {
    final error = await Isolate.run(() {
      final from = source.toNativeUtf8(), to = destination.toNativeUtf8();
      final backup = recovery.toNativeUtf8();
      try {
        return _replaceFile(from, to, backup);
      } finally {
        malloc.free(from);
        malloc.free(to);
        malloc.free(backup);
      }
    });
    if (error == 0) return;
    if (!Platform.isWindows ||
        !const [32, 33].contains(error) ||
        DateTime.now().isAfter(deadline)) {
      throw FileSystemException(
        'File replacement failed. Recovery copy, if present: $recovery',
        destination,
        OSError('Native replacement', error),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final current = await observeFile(destination);
    if (current.status != baseline!.status ||
        current.identity != baseline.identity ||
        current.sha256Hex != baseline.sha256Hex) {
      throw FileSystemException(
        'The file changed while waiting to replace it',
        destination,
      );
    }
  }
}

/// Flushes staged bytes, including the drive cache on macOS, before a name
/// is published. Failure must leave the destination untouched.
Future<void> syncFile(String path) => Isolate.run(() {
  _checkPath(path);
  final value = path.toNativeUtf8();
  try {
    final error = _syncFile(value);
    if (error != 0) {
      throw FileSystemException(
        'File synchronization failed',
        path,
        OSError('Native file sync', error),
      );
    }
  } finally {
    malloc.free(value);
  }
});

/// Bytes and identity from the same native file handle, checked against its
/// path after reading. Missing/failed observations never contain partial bytes.
class NativeFileObservation {
  NativeFileObservation({
    required this.status,
    required this.error,
    this.identity,
    this.volume,
    this.bytes,
    this.sha256Hex,
  });
  final int status;
  final int error;
  final String? identity;

  /// Native volume observed with this file, for same-filesystem admission.
  /// This is not decoded from the opaque serialized identity.
  final int? volume;
  final Uint8List? bytes;
  final String? sha256Hex;
}

Future<NativeFileObservation> observeFile(String path) =>
    Isolate.run(() => _observeFile(path));

/// Observes an ordered prefix in one isolate using the same native checks as
/// [observeFile]. Copy [paths] before dispatch so caller mutations cannot change
/// the requested files. This is not an atomic snapshot across multiple files.
///
/// A nonempty input always observes at least one file. Stop after accumulated
/// successful bytes reach [maxBytes]; the last file may exceed that budget.
/// Missing/refused files count as zero bytes. Callers bound candidate count and
/// advance by the returned length to read the remaining paths.
Future<List<NativeFileObservation>> observeFileBatch(
  List<String> paths, {
  int maxBytes = 16 * 1024 * 1024,
}) async {
  if (maxBytes <= 0)
    throw ArgumentError.value(maxBytes, 'maxBytes', 'Must be positive');
  final requested = List<String>.of(paths);
  return Isolate.run(() {
    final observations = <NativeFileObservation>[];
    var bytes = 0;
    for (final path in requested) {
      final observed = _observeFile(path);
      observations.add(observed);
      bytes += observed.bytes?.length ?? 0;
      if (bytes >= maxBytes) break;
    }
    return List<NativeFileObservation>.unmodifiable(observations);
  });
}

NativeFileObservation _observeFile(String path) {
  _checkPath(path);
  final nativePath = path.toNativeUtf8();
  Pointer<_Snapshot> result = nullptr;
  try {
    result = _read(nativePath);
    if (result == nullptr) throw const OutOfMemoryError();
    final value = result.ref;
    final bytes = value.status == 0
        ? Uint8List.fromList(
            value.bytes.asTypedList(value.size),
          ).asUnmodifiableView()
        : null;
    return NativeFileObservation(
      status: value.status,
      error: value.error,
      identity: value.status == 0
          ? '${value.volume}:${value.high}:${value.low}'
          : null,
      volume: value.status == 0 ? value.volume : null,
      bytes: bytes,
      sha256Hex: bytes == null ? null : sha256.convert(bytes).toString(),
    );
  } finally {
    if (result != nullptr) _free(result);
    malloc.free(nativePath);
  }
}

class NativeNameCollision implements Exception {
  const NativeNameCollision(this.path);
  final String path;
}

/// Native object identity for a directory, without following its final link.
/// Missing is status 1; every other nonzero status must fail closed.
Future<({int status, String? identity, int? volume})> observeDirectory(
  String path,
) => Isolate.run(() {
  _checkPath(path);
  final nativePath = path.toNativeUtf8();
  Pointer<_Snapshot> result = nullptr;
  try {
    result = _directoryIdentity(nativePath);
    if (result == nullptr) throw const OutOfMemoryError();
    final value = result.ref;
    return (
      status: value.status,
      identity: value.status == 0
          ? '${value.volume}:${value.high}:${value.low}'
          : null,
      volume: value.status == 0 ? value.volume : null,
    );
  } finally {
    if (result != nullptr) _free(result);
    malloc.free(nativePath);
  }
});

Future<void> installNewFile(String source, String destination) =>
    Isolate.run(() {
      _checkPath(source);
      _checkPath(destination);
      final from = source.toNativeUtf8(), to = destination.toNativeUtf8();
      try {
        final error = _installNew(from, to);
        if (error == (Platform.isWindows ? 80 : 17) ||
            (Platform.isWindows && error == 183)) {
          throw NativeNameCollision(destination);
        }
        if (error != 0) {
          throw FileSystemException(
            'Exclusive publication failed',
            destination,
            OSError('Native publication', error),
          );
        }
      } finally {
        malloc.free(from);
        malloc.free(to);
      }
    });

Future<void> syncDirectory(String path) => Isolate.run(() {
  _checkPath(path);
  final value = path.toNativeUtf8();
  try {
    final error = _syncDirectory(value);
    if (error != 0) {
      throw FileSystemException(
        'Directory synchronization unavailable or failed',
        path,
        OSError('Native directory sync', error),
      );
    }
  } finally {
    malloc.free(value);
  }
});

Future<void> movePathNoReplace(String source, String destination) =>
    Isolate.run(() {
      _checkPath(source);
      _checkPath(destination);
      final from = source.toNativeUtf8(), to = destination.toNativeUtf8();
      try {
        final error = _movePathNoReplace(from, to);
        if (error == (Platform.isWindows ? 80 : 17) ||
            (Platform.isWindows && error == 183)) {
          throw NativeNameCollision(destination);
        }
        if (error != 0) {
          throw FileSystemException(
            'Exclusive path move failed',
            destination,
            OSError('Native move', error),
          );
        }
      } finally {
        malloc.free(from);
        malloc.free(to);
      }
    });

void _checkPath(String path) {
  if (path.contains('\u0000')) {
    throw ArgumentError.value(
      path,
      'path',
      'NUL is not a valid path character',
    );
  }
}
