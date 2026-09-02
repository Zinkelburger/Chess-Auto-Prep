/// Streaming zstandard decompression, for expanding `lichess_db_eval.jsonl.zst`.
///
/// The download is 21.7 GB compressed and about 283 GB expanded, so it is
/// never written out — the importer reads this stream and keeps four numbers
/// per line.  Two backends, tried in order:
///
///   * **libzstd through FFI.**  No subprocess, and the library is already on
///     every desktop that matters: on Linux `libzstd.so.1` is pulled in by
///     systemd and the package manager itself, and macOS has shipped
///     `/usr/lib/libzstd.1.dylib` since Big Sur.
///   * **The `zstd` command.**  The fallback for Windows, where nothing
///     bundles the library, and for anyone whose distribution moved it.
///
/// Both yield the same `Stream<List<int>>` of expanded bytes, so the importer
/// does not know which one it got.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Which decompressor this machine can offer.
enum ZstdBackend {
  /// libzstd, loaded in-process.
  library,

  /// The `zstd` executable on PATH.
  commandLine,

  /// Neither — the import cannot run.
  none,
}

class ZstdException implements Exception {
  const ZstdException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Candidate library names, most specific first.
List<String> _libraryNames() {
  if (Platform.isLinux) {
    return const ['libzstd.so.1', 'libzstd.so'];
  }
  if (Platform.isMacOS) {
    return const [
      'libzstd.1.dylib',
      '/usr/lib/libzstd.1.dylib',
      '/opt/homebrew/lib/libzstd.dylib',
      '/usr/local/lib/libzstd.dylib',
      'libzstd.dylib',
    ];
  }
  if (Platform.isWindows) {
    return const ['libzstd.dll', 'zstd.dll'];
  }
  return const [];
}

_ZstdLib? _cachedLib;
bool _libProbed = false;

_ZstdLib? _loadLibrary() {
  if (_libProbed) return _cachedLib;
  _libProbed = true;
  for (final name in _libraryNames()) {
    try {
      return _cachedLib = _ZstdLib(DynamicLibrary.open(name));
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// True when the `zstd` executable answers `--version`.
Future<bool> hasZstdCommand() async {
  try {
    final result = await Process.run('zstd', ['--version']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

ZstdBackend? _probedBackend;

/// The backend [openZstdStream] would use, probed once per run.
Future<ZstdBackend> probeZstdBackend() async {
  final known = _probedBackend;
  if (known != null) return known;
  if (_loadLibrary() != null) return _probedBackend = ZstdBackend.library;
  if (await hasZstdCommand()) return _probedBackend = ZstdBackend.commandLine;
  return _probedBackend = ZstdBackend.none;
}

/// What to tell the user when [probeZstdBackend] returns [ZstdBackend.none].
String get zstdMissingMessage => Platform.isWindows
    ? 'The Lichess file is zstd-compressed and no decompressor was found. '
          'Install zstd (winget install Facebook.Zstandard) and try again.'
    : 'The Lichess file is zstd-compressed and no decompressor was found. '
          'Install the zstd package (libzstd) and try again.';

/// Expanded bytes of the zstd file at [path].
///
/// [prefer] forces a backend; tests use it to exercise both.  Throws
/// [ZstdException] when the chosen backend is unavailable or the stream is
/// corrupt.
Stream<List<int>> openZstdStream(String path, {ZstdBackend? prefer}) async* {
  final backend = prefer ?? await probeZstdBackend();
  switch (backend) {
    case ZstdBackend.library:
      final lib = _loadLibrary();
      if (lib == null) throw const ZstdException('libzstd is not available');
      yield* _libraryStream(lib, path);
    case ZstdBackend.commandLine:
      yield* _commandStream(path);
    case ZstdBackend.none:
      throw ZstdException(zstdMissingMessage);
  }
}

Stream<List<int>> _libraryStream(_ZstdLib lib, String path) async* {
  final decoder = _StreamDecoder(lib);
  try {
    await for (final chunk in File(path).openRead()) {
      for (final out in decoder.feed(chunk)) {
        yield out;
      }
    }
    decoder.finish();
  } finally {
    decoder.dispose();
  }
}

Stream<List<int>> _commandStream(String path) async* {
  final Process process;
  try {
    process = await Process.start('zstd', ['-dc', '--', path]);
  } on ProcessException catch (e) {
    throw ZstdException('could not run zstd: ${e.message}');
  }
  // Unread stderr fills its pipe and wedges the child, so drain it alongside.
  final stderrText = StringBuffer();
  final draining = process.stderr
      .listen((bytes) => stderrText.write(String.fromCharCodes(bytes)))
      .asFuture<void>();
  try {
    yield* process.stdout;
  } finally {
    await draining.catchError((_) {});
  }
  final code = await process.exitCode;
  if (code != 0) {
    throw ZstdException(
      'zstd exited with $code: ${stderrText.toString().trim()}',
    );
  }
}

// ── FFI ──────────────────────────────────────────────────────────────────

final class _ZstdInBuffer extends Struct {
  external Pointer<Uint8> src;
  @IntPtr()
  external int size;
  @IntPtr()
  external int pos;
}

final class _ZstdOutBuffer extends Struct {
  external Pointer<Uint8> dst;
  @IntPtr()
  external int size;
  @IntPtr()
  external int pos;
}

typedef _CreateDStreamC = Pointer<Void> Function();
typedef _FreeDStreamC = IntPtr Function(Pointer<Void>);
typedef _InitDStreamC = IntPtr Function(Pointer<Void>);
typedef _DecompressStreamC =
    IntPtr Function(
      Pointer<Void>,
      Pointer<_ZstdOutBuffer>,
      Pointer<_ZstdInBuffer>,
    );
typedef _SizeC = IntPtr Function();
typedef _IsErrorC = Uint32 Function(IntPtr);
typedef _IsErrorDart = int Function(int);
typedef _ErrorNameC = Pointer<Utf8> Function(IntPtr);

class _ZstdLib {
  _ZstdLib(DynamicLibrary lib)
    : createDStream = lib
          .lookupFunction<_CreateDStreamC, Pointer<Void> Function()>(
            'ZSTD_createDStream',
          ),
      freeDStream = lib
          .lookupFunction<_FreeDStreamC, int Function(Pointer<Void>)>(
            'ZSTD_freeDStream',
          ),
      initDStream = lib
          .lookupFunction<_InitDStreamC, int Function(Pointer<Void>)>(
            'ZSTD_initDStream',
          ),
      decompressStream = lib
          .lookupFunction<
            _DecompressStreamC,
            int Function(
              Pointer<Void>,
              Pointer<_ZstdOutBuffer>,
              Pointer<_ZstdInBuffer>,
            )
          >('ZSTD_decompressStream'),
      outSize = lib.lookupFunction<_SizeC, int Function()>(
        'ZSTD_DStreamOutSize',
      ),
      isError = lib.lookupFunction<_IsErrorC, _IsErrorDart>('ZSTD_isError'),
      errorName = lib.lookupFunction<_ErrorNameC, Pointer<Utf8> Function(int)>(
        'ZSTD_getErrorName',
      );

  final Pointer<Void> Function() createDStream;
  final int Function(Pointer<Void>) freeDStream;
  final int Function(Pointer<Void>) initDStream;
  final int Function(
    Pointer<Void>,
    Pointer<_ZstdOutBuffer>,
    Pointer<_ZstdInBuffer>,
  )
  decompressStream;
  final int Function() outSize;
  final int Function(int) isError;
  final Pointer<Utf8> Function(int) errorName;
}

/// One decompression session over reusable native buffers.
class _StreamDecoder {
  _StreamDecoder(this._lib) {
    _stream = _lib.createDStream();
    if (_stream == nullptr) {
      throw const ZstdException('ZSTD_createDStream failed');
    }
    _check(_lib.initDStream(_stream));
    _outCapacity = _lib.outSize();
    if (_outCapacity <= 0) _outCapacity = 1 << 17;
    _inPtr = calloc<Uint8>(_inCapacity);
    _outPtr = calloc<Uint8>(_outCapacity);
    _inBuffer = calloc<_ZstdInBuffer>();
    _outBuffer = calloc<_ZstdOutBuffer>();
  }

  static const int _inCapacity = 1 << 18; // 256 KB

  final _ZstdLib _lib;
  late final Pointer<Void> _stream;
  late final int _outCapacity;
  late final Pointer<Uint8> _inPtr;
  late final Pointer<Uint8> _outPtr;
  late final Pointer<_ZstdInBuffer> _inBuffer;
  late final Pointer<_ZstdOutBuffer> _outBuffer;
  bool _disposed = false;
  int _lastResult = 0;
  bool _sawInput = false;

  /// Expanded chunks produced by [chunk]; may be empty while zstd buffers.
  Iterable<Uint8List> feed(List<int> chunk) sync* {
    if (_disposed) throw const ZstdException('decoder used after dispose');
    var offset = 0;
    final inView = _inPtr.asTypedList(_inCapacity);
    final outView = _outPtr.asTypedList(_outCapacity);
    while (offset < chunk.length) {
      final take = (chunk.length - offset) < _inCapacity
          ? chunk.length - offset
          : _inCapacity;
      inView.setRange(0, take, chunk, offset);
      offset += take;
      _sawInput = true;

      _inBuffer.ref
        ..src = _inPtr
        ..size = take
        ..pos = 0;
      while (_inBuffer.ref.pos < _inBuffer.ref.size) {
        final consumedBefore = _inBuffer.ref.pos;
        _outBuffer.ref
          ..dst = _outPtr
          ..size = _outCapacity
          ..pos = 0;
        _lastResult = _lib.decompressStream(_stream, _outBuffer, _inBuffer);
        _check(_lastResult);
        final produced = _outBuffer.ref.pos;
        if (produced > 0) {
          yield Uint8List.fromList(outView.sublist(0, produced));
        }
        // zstd may consume input without emitting anything, but it always
        // makes progress on one side or the other; stalling on both means
        // there is nothing more this chunk can do.
        if (produced == 0 && _inBuffer.ref.pos == consumedBefore) break;
      }
    }
  }

  /// Asserts the stream ended on a frame boundary.
  ///
  /// `ZSTD_decompressStream` returns 0 exactly when it has just finished a
  /// frame; any other value is a hint for how much more input it wants.  A
  /// truncated download therefore ends on a non-zero result, and without this
  /// check it would look like a short but successful read — which for the
  /// importer would mean silently building a partial database.
  void finish() {
    if (!_sawInput) return;
    if (_lastResult != 0) {
      throw const ZstdException(
        'the archive ends mid-frame — the download is incomplete',
      );
    }
  }

  void _check(int code) {
    if (_lib.isError(code) != 0) {
      throw ZstdException('zstd: ${_lib.errorName(code).toDartString()}');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lib.freeDStream(_stream);
    calloc
      ..free(_inPtr)
      ..free(_outPtr)
      ..free(_inBuffer)
      ..free(_outBuffer);
  }
}
