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

/// Bytes and identity from the same native file handle, checked against its
/// path after reading. Missing/failed observations never contain partial bytes.
class NativeFileObservation {
  NativeFileObservation({
    required this.status,
    required this.error,
    this.identity,
    this.bytes,
    this.sha256Hex,
  });
  final int status;
  final int error;
  final String? identity;
  final Uint8List? bytes;
  final String? sha256Hex;
}

Future<NativeFileObservation> observeFile(String path) => Isolate.run(() {
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
      bytes: bytes,
      sha256Hex: bytes == null ? null : sha256.convert(bytes).toString(),
    );
  } finally {
    if (result != nullptr) _free(result);
    malloc.free(nativePath);
  }
});

class NativeNameCollision implements Exception {
  const NativeNameCollision(this.path);
  final String path;
}

/// Native object identity for a directory, without following its final link.
/// Missing is status 1; every other nonzero status must fail closed.
Future<({int status, String? identity})> observeDirectory(String path) =>
    Isolate.run(() {
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
