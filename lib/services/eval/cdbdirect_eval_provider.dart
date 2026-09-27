/// FFI-backed cdbdirect eval provider (libcdbdirect).
///
/// Loads the bundled reader from [cdbdirect_flutter_libs] first, then falls
/// back to system paths for development.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:cdbdirect_flutter_libs/cdbdirect_flutter_libs.dart' as cdb_libs;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../utils/fen_utils.dart';
import 'cdbdirect_parse.dart';
import 'chessdb_score.dart';
import 'db_move_list.dart';
import '../../chess_core/position/eval_canonicalize.dart';
import 'external_eval_provider.dart';

typedef _InitializeNative = Pointer<Void> Function(Pointer<Utf8> path);
typedef _InitializeDart = Pointer<Void> Function(Pointer<Utf8> path);

typedef _GetNative =
    Pointer<Utf8> Function(Pointer<Void> handle, Pointer<Utf8> fen);
typedef _GetDart =
    Pointer<Utf8> Function(Pointer<Void> handle, Pointer<Utf8> fen);

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
  });

  /// Native reader loaded (bundled .so or dev LD_LIBRARY_PATH / TERARKDBROOT).
  final bool isAvailable;

  /// Whether the ChessDB dump UI should appear (Linux only).
  final bool showFeatureUi;
  final String platformName;
}

/// The four `cdbdirect_*` entry points, resolved once per loaded library.
class _CdbDirectBindings {
  _CdbDirectBindings(DynamicLibrary lib)
    : initialize = lib.lookupFunction<_InitializeNative, _InitializeDart>(
        'cdbdirect_initialize',
      ),
      get = lib.lookupFunction<_GetNative, _GetDart>('cdbdirect_get'),
      size = lib.lookupFunction<_SizeNative, _SizeDart>('cdbdirect_size'),
      finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>(
        'cdbdirect_finalize',
      );

  final _InitializeDart initialize;
  final _GetDart get;
  final _SizeDart size;
  final _FinalizeDart finalize;
}

/// An opened dump: the bindings plus the native handle they were opened with.
class _OpenDump {
  const _OpenDump(this.bindings, this.handle);

  final _CdbDirectBindings bindings;
  final Pointer<Void> handle;

  String? get(String fenKey) {
    final fenPtr = fenKey.toNativeUtf8();
    try {
      final response = bindings.get(handle, fenPtr);
      return response.address == 0 ? null : response.toDartString();
    } finally {
      malloc.free(fenPtr);
    }
  }

  int get positionCount => bindings.size(handle);

  void close() => bindings.finalize(handle);
}

class CdbDirectEvalProvider
    implements ExternalEvalProvider, ExternalMoveProvider {
  static bool? _libraryLoadable;

  _OpenDump? _dump;

  final String path;
  final CdbDirectLookupFn? lookupOverride;

  CdbDirectEvalProvider({required this.path, this.lookupOverride});

  /// Whether the native reader can be loaded on this machine (cached after
  /// [probeAvailability]).
  static bool get isAvailable => _libraryLoadable ?? false;

  /// Linux shows the ChessDB dump UI even when the native library is not
  /// built yet.
  static bool get showFeatureUi => Platform.isLinux;

  /// Whether this provider instance is ready to serve lookups.
  bool get isReady => _dump != null || lookupOverride != null;

  /// Probe and cache whether libcdbdirect is loadable. Safe to call multiple
  /// times.
  static Future<bool> probeAvailability() async {
    return _libraryLoadable ??= (await libraryStatus()).isAvailable;
  }

  int? get positionCount => _dump?.positionCount;

  /// Probe whether a cdbdirect library can be loaded on this platform.
  static Future<CdbDirectLibraryStatus> libraryStatus() async {
    final platformName = cdb_libs.platformDisplayName;
    if (!Platform.isLinux) {
      return CdbDirectLibraryStatus(
        isAvailable: false,
        showFeatureUi: false,
        platformName: platformName,
      );
    }
    return CdbDirectLibraryStatus(
      isAvailable: await _tryLoadLibrary() != null,
      showFeatureUi: true,
      platformName: platformName,
    );
  }

  /// Load bundled library first, then dev/system fallbacks.
  static Future<DynamicLibrary?> _tryLoadLibrary() async {
    final bundled = cdb_libs.openLibrary();
    if (bundled != null) return bundled;
    return _tryLoadDevLibrary();
  }

  static DynamicLibrary? _openLibraryPath(String libPath) {
    try {
      return DynamicLibrary.open(libPath);
    } catch (_) {
      // Not at this path; the caller tries the next candidate.
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

    final projectRoot = env['CHESS_AUTO_PREP_ROOT'];
    final projectRoots = <String>{
      if (projectRoot != null && projectRoot.isNotEmpty) projectRoot,
      Directory.current.path,
    };
    for (final root in projectRoots) {
      yield p.join(
        root,
        'tree_builder',
        'deps',
        'install',
        'lib',
        'libcdbdirect.so',
      );
    }

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      yield p.join(exeDir, 'lib', 'libcdbdirect.so');
      yield p.join(exeDir, '..', 'lib', 'libcdbdirect.so');
    } catch (_) {
      // resolvedExecutable may throw on some platforms; skip those candidates.
    }
  }

  static Future<DynamicLibrary?> _tryLoadDevLibrary() async {
    if (!Platform.isLinux) return null;

    const names = ['libcdbdirect.so', 'libcdbdirect.dylib', 'cdbdirect.dll'];
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
    if (_dump != null) return true;
    if (path.isEmpty) return false;
    if (!await validateCdbDirectDataDir(path)) return false;

    final lib = library ?? await _tryLoadLibrary();
    if (lib == null) return false;

    final _CdbDirectBindings bindings;
    try {
      bindings = _CdbDirectBindings(lib);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CdbDirectEvalProvider] symbol load failed: $e');
      }
      return false;
    }

    final resolved = await resolveCdbDirectDataDir(path);
    final openPath = resolved?.path ?? path;
    final pathPtr = openPath.toNativeUtf8();
    final Pointer<Void> handle;
    try {
      handle = bindings.initialize(pathPtr);
    } finally {
      malloc.free(pathPtr);
    }

    if (handle.address == 0) return false;
    _dump = _OpenDump(bindings, handle);
    return true;
  }

  Future<void> close() async {
    _dump?.close();
    _dump = null;
  }

  String? _nativeLookup(String fenKey) {
    final override = lookupOverride;
    if (override != null) return override(fenKey);
    return _dump?.get(fenKey);
  }

  /// Every move the dump knows from [fen], best first; empty on a miss.
  ///
  /// The same native call [lookup] makes — the dump answers with the whole
  /// ranked list and the eval path keeps only the top score. No [minDepth]
  /// gate: the dump reports no per-move depth, and a book build wants the
  /// database's ranking regardless.
  @override
  Future<DbMoveList> lookupMoves(String fen) async {
    if (!isReady) return DbMoveList.empty;
    try {
      final moves = parseCdbDirectMoveList(
        _nativeLookup(canonicalizeFen4(fen)),
      );
      if (moves.isEmpty) return DbMoveList.empty;
      return DbMoveList(moves: moves, source: DbMoveSource.cdbDirect);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CdbDirectEvalProvider] move lookup failed: $e');
      }
      return DbMoveList.empty;
    }
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    if (!isReady) return const EvalLookupResult.miss();

    final key = canonicalizeFen4(fen);
    final isWhiteStm = isWhiteToMove(key);

    try {
      final parsed = parseCdbDirectResponse(_nativeLookup(key));
      if (parsed == null) return const EvalLookupResult.hardMiss();

      // The dump scores like the API: side-to-move centipawns with mates
      // encoded as ±(30000 − ply).  Decode them the same way the API path
      // does, so the chain never sees a 29995-centipawn "eval" from here.
      final decoded = mapChessDbRawScoreStm(parsed.score);
      final whiteCp = isWhiteStm ? decoded.stmCp : -decoded.stmCp;
      if (parsed.depth < minDepth) return const EvalLookupResult.shallow();

      return EvalLookupResult.found(
        EvalHit(
          cp: whiteCp,
          mate: decoded.mate,
          depth: parsed.depth,
          bestMove: parsed.bestMove,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[CdbDirectEvalProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    }
  }
}
