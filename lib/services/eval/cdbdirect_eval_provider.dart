/// FFI-backed cdbdirect eval provider (libcdbdirect).
///
/// Loads the bundled reader from [cdbdirect_flutter_libs] first, then falls
/// back to system paths for development.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:cdbdirect_flutter_libs/cdbdirect_flutter_libs.dart'
    as cdb_libs;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'cdbdirect_parse.dart';
import 'eval_canonicalize.dart';
import 'external_eval_provider.dart';

typedef _InitializeNative = Pointer<Void> Function(Pointer<Utf8> path);
typedef _InitializeDart = Pointer<Void> Function(Pointer<Utf8> path);

typedef _GetNative = Pointer<Utf8> Function(Pointer<Void> handle, Pointer<Utf8> fen);
typedef _GetDart = Pointer<Utf8> Function(Pointer<Void> handle, Pointer<Utf8> fen);

typedef _SizeNative = IntPtr Function(Pointer<Void> handle);
typedef _SizeDart = int Function(Pointer<Void> handle);

typedef _FinalizeNative = Void Function(Pointer<Void> handle);
typedef _FinalizeDart = void Function(Pointer<Void> handle);

/// Injectable lookup for tests (bypasses FFI).
typedef CdbDirectLookupFn = String? Function(String fen);

/// Availability of the native cdbdirect reader on this machine.
class CdbDirectLibraryStatus {
  const CdbDirectLibraryStatus({
    required this.isAvailable,
    required this.showFeatureUi,
    required this.platformName,
    required this.usedBundledLibrary,
  });

  /// Native reader loaded (bundled .so or dev LD_LIBRARY_PATH / TERARKDBROOT).
  final bool isAvailable;

  /// Whether the ChessDB dump UI should appear (Linux only).
  final bool showFeatureUi;
  final String platformName;
  final bool usedBundledLibrary;
}

class CdbDirectEvalProvider implements ExternalEvalProvider {
  static bool? _libraryLoadable;

  DynamicLibrary? _lib;
  Pointer<Void>? _handle;

  _InitializeDart? _initialize;
  _GetDart? _get;
  _SizeDart? _size;
  _FinalizeDart? _finalize;

  final String path;
  final CdbDirectLookupFn? lookupOverride;

  CdbDirectEvalProvider({
    required this.path,
    this.lookupOverride,
  });

  /// Whether the native reader can be loaded on this machine (cached after [probeAvailability]).
  static bool get isAvailable => _libraryLoadable ?? false;

  /// Linux shows the ChessDB dump UI even when the native library is not built yet.
  static bool get showFeatureUi => Platform.isLinux;

  /// Whether this provider instance is ready to serve lookups.
  bool get isReady => _handle != null || lookupOverride != null;

  /// Probe and cache whether libcdbdirect is loadable. Safe to call multiple times.
  static Future<bool> probeAvailability() async {
    if (_libraryLoadable != null) return _libraryLoadable!;
    final status = await libraryStatus();
    _libraryLoadable = status.isAvailable;
    return _libraryLoadable!;
  }

  int? get positionCount {
    if (_handle == null || _size == null) return null;
    return _size!(_handle!);
  }

  /// Probe whether a cdbdirect library can be loaded on this platform.
  static Future<CdbDirectLibraryStatus> libraryStatus() async {
    final platformName = cdb_libs.platformDisplayName;
    if (!Platform.isLinux) {
      return CdbDirectLibraryStatus(
        isAvailable: false,
        showFeatureUi: false,
        platformName: platformName,
        usedBundledLibrary: false,
      );
    }

    final bundled = cdb_libs.openLibrary();
    if (bundled != null) {
      return CdbDirectLibraryStatus(
        isAvailable: true,
        showFeatureUi: true,
        platformName: platformName,
        usedBundledLibrary: true,
      );
    }

    final dev = await _tryLoadDevLibrary();
    return CdbDirectLibraryStatus(
      isAvailable: dev != null,
      showFeatureUi: true,
      platformName: platformName,
      usedBundledLibrary: false,
    );
  }

  /// Load bundled library first, then dev/system fallbacks.
  static Future<DynamicLibrary?> tryLoadLibrary() async {
    final bundled = cdb_libs.openLibrary();
    if (bundled != null) return bundled;
    return _tryLoadDevLibrary();
  }

  static DynamicLibrary? _openLibraryPath(String libPath) {
    try {
      return DynamicLibrary.open(libPath);
    } catch (_) {
      return null;
    }
  }

  /// Dev / local install paths checked after bundled loader and soname lookup.
  static Iterable<String> _devLibraryPathCandidates() sync* {
    final env = Platform.environment;

    final direct = env['CDBDIRECT_LIB'];
    if (direct != null && direct.isNotEmpty) yield direct;

    final envRoot = env['TERARKDBROOT'];
    if (envRoot != null && envRoot.isNotEmpty) {
      yield p.join(envRoot, 'lib', 'libcdbdirect.so');
      yield p.join(envRoot, 'lib', 'libcdbdirect.dylib');
      yield p.join(envRoot, 'lib', 'cdbdirect.dll');
    }

    final projectRoots = <String>{
      if (env['CHESS_AUTO_PREP_ROOT']?.isNotEmpty == true)
        env['CHESS_AUTO_PREP_ROOT']!,
      Directory.current.path,
    };
    for (final root in projectRoots) {
      yield p.join(root, 'tree_builder', 'deps', 'install', 'lib', 'libcdbdirect.so');
    }

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      yield p.join(exeDir, 'lib', 'libcdbdirect.so');
      yield p.join(exeDir, '..', 'lib', 'libcdbdirect.so');
    } catch (_) {}
  }

  static Future<DynamicLibrary?> _tryLoadDevLibrary() async {
    if (!Platform.isLinux) return null;

    const names = [
      'libcdbdirect.so',
      'libcdbdirect.dylib',
      'cdbdirect.dll',
    ];
    for (final name in names) {
      final lib = _openLibraryPath(name);
      if (lib != null) return lib;
    }

    for (final libPath in _devLibraryPathCandidates()) {
      final lib = _openLibraryPath(libPath);
      if (lib != null) return lib;
    }
    return null;
  }

  Future<bool> init({DynamicLibrary? library}) async {
    if (lookupOverride != null) return path.isNotEmpty;
    if (_handle != null) return true;
    if (path.isEmpty) return false;
    if (!await validateCdbDirectDataDir(path)) return false;

    _lib = library ?? await tryLoadLibrary();
    if (_lib == null) return false;

    try {
      _initialize = _lib!
          .lookupFunction<_InitializeNative, _InitializeDart>('cdbdirect_initialize');
      _get = _lib!.lookupFunction<_GetNative, _GetDart>('cdbdirect_get');
      _size = _lib!.lookupFunction<_SizeNative, _SizeDart>('cdbdirect_size');
      _finalize =
          _lib!.lookupFunction<_FinalizeNative, _FinalizeDart>('cdbdirect_finalize');
    } catch (e) {
      if (kDebugMode) debugPrint('[CdbDirectEvalProvider] symbol load failed: $e');
      _lib = null;
      return false;
    }

    final resolved = await resolveCdbDirectDataDir(path);
    final openPath = resolved?.path ?? path;
    final pathPtr = openPath.toNativeUtf8();
    try {
      _handle = _initialize!(pathPtr);
    } finally {
      malloc.free(pathPtr);
    }

    if (_handle == null || _handle!.address == 0) {
      _handle = null;
      return false;
    }
    return true;
  }

  Future<void> close() async {
    if (_handle != null && _finalize != null) {
      _finalize!(_handle!);
      _handle = null;
    }
  }

  String? _nativeLookup(String fenKey) {
    if (lookupOverride != null) return lookupOverride!(fenKey);
    if (_handle == null || _get == null) return null;

    final fenPtr = fenKey.toNativeUtf8();
    try {
      final respPtr = _get!(_handle!, fenPtr);
      if (respPtr.address == 0) return null;
      return respPtr.toDartString();
    } finally {
      malloc.free(fenPtr);
    }
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    if (!isReady) return const EvalLookupResult.miss();

    final key = canonicalizeFen4(fen);
    final isWhiteStm = key.split(' ').length >= 2 && key.split(' ')[1] == 'w';

    try {
      final response = _nativeLookup(key);
      final parsed = parseCdbDirectResponse(response);
      if (parsed == null) return const EvalLookupResult.hardMiss();

      final whiteCp = isWhiteStm ? parsed.cp : -parsed.cp;
      if (parsed.depth < minDepth) return const EvalLookupResult.shallow();

      return EvalLookupResult.found(EvalHit(
        cp: whiteCp,
        depth: parsed.depth,
        bestMove: parsed.bestMove,
      ));
    } catch (e) {
      if (kDebugMode) debugPrint('[CdbDirectEvalProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    }
  }
}
