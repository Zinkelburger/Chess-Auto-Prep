import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// Where the installed engine is, and the directory that is its home: it is
/// started there, and its runtime library is found there.
typedef HivemindFiles = ({String executable, String model, String directory});

sealed class HivemindLocation {
  const HivemindLocation();
}

final class HivemindReady extends HivemindLocation {
  const HivemindReady(this.files);

  final HivemindFiles files;
}

final class HivemindMissing extends HivemindLocation {
  const HivemindMissing(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// Puts Hivemind, the bughouse engine, where it can run: the engine, its
/// ONNX Runtime library and its 54 MB network, shipped gzipped under
/// `assets/bughouse/` beside a `manifest.json` of each extracted file's size
/// and SHA-256.
///
/// Every file is checked against the manifest before every launch, not only
/// the first: a file cut short by a killed install, or damaged on the disk,
/// keeps its name and would otherwise be trusted for ever — and Windows
/// reports a truncated library as the same opaque `0xC000007B` it gives a
/// 32-bit one. A file that does not match is written again from the asset,
/// under a temporary name and checked before it replaces anything. The old
/// app installs into the same `bughouse/` folder the same way, so both apps
/// share one copy.
///
/// On Windows the build's private Visual C++ runtime, under
/// `data/bughouse-runtime/` beside the app, is copied in the same checked
/// way, so the engine never loads whatever `MSVCP140.dll` the machine's
/// PATH offers first.
///
/// Hivemind is © 2026 aminwoo, MIT; the notice is bundled at
/// `assets/licenses/HIVEMIND_LICENSE.txt`.
final class HivemindInstall {
  HivemindInstall({
    required this.supportDirectory,
    required this.readAsset,
    Directory? appDirectory,
  }) : appDirectory = appDirectory ?? File(Platform.resolvedExecutable).parent;

  final Directory supportDirectory;

  /// Reads a bundled asset, or null when the build has none by that name.
  final Future<Uint8List?> Function(String asset) readAsset;

  /// The folder the app runs from, where a Windows build keeps its runtime.
  final Directory appDirectory;

  /// Whether a build whose assets are [assetKeys] carries an engine for this
  /// platform: all three files and the manifest they are checked against.
  /// The bughouse assets are fetched by `tools/fetch_assets.py`, not kept in
  /// git, so a build without them is ordinary and hides the mode.
  static bool bundledIn(Iterable<String> assetKeys) {
    final keys = assetKeys.toSet();
    return [
      for (final name in installedNames) '$_assets/$name.gz',
      '$_assets/manifest.json',
    ].every(keys.contains);
  }

  /// The three files, by the names they are installed under.
  static List<String> get installedNames => [_binaryName, _runtimeName, _model];

  /// The look, and install if needed, in flight for each support folder.
  ///
  /// Every launch makes its own [HivemindInstall], and two launches during a
  /// first install would write one partial file, one renaming it into place
  /// while the other was still writing it. A launch that finds one in flight
  /// shares its answer; another process names its partial files after its
  /// own [pid].
  static final _locating = <String, Future<HivemindLocation>>{};

  Future<HivemindLocation> locate() {
    final key = p.normalize(p.absolute(supportDirectory.path));
    // `remove` hands back this same future, which the callback must not
    // return: `whenComplete` would wait for it and never finish.
    return _locating[key] ??= _locate().whenComplete(
      () => _locating.remove(key)?.ignore(),
    );
  }

  Future<HivemindLocation> _locate() async {
    final bytes = await readAsset('$_assets/manifest.json');
    if (bytes == null) {
      return const HivemindMissing('This build has no bughouse engine.');
    }
    final manifest = _Manifest.read(utf8.decode(bytes), installedNames);
    if (manifest == null) {
      log.e('read $_assets/manifest.json', 'a file has no size or SHA-256');
      return const HivemindMissing(
        'The bughouse engine’s manifest is damaged; reinstall the app.',
      );
    }
    final folder = Directory(p.join(supportDirectory.path, 'bughouse'));
    try {
      final problem = await _installAll(folder, manifest);
      if (problem != null) {
        log.e('install the bughouse engine', problem);
        return HivemindMissing(problem);
      }
    } on Object catch (error) {
      log.e('install the bughouse engine', error);
      return HivemindMissing('Could not install the bughouse engine: $error');
    }
    return HivemindReady((
      executable: p.join(folder.path, _binaryName),
      model: p.join(folder.path, _model),
      directory: folder.path,
    ));
  }

  /// Every file in [folder] as [manifest] promises it; answers the first
  /// problem, or null.
  Future<String?> _installAll(Directory folder, _Manifest manifest) async {
    await folder.create(recursive: true);
    await _sweepLeftovers(folder);
    for (final name in installedNames) {
      final problem = await _ensure(folder, name, manifest.files[name]!);
      if (problem != null) return problem;
    }
    if (Platform.isWindows) return _windowsRuntime(folder);
    final binary = p.join(folder.path, _binaryName);
    final chmod = await Process.run('chmod', ['+x', binary]);
    if (chmod.exitCode != 0) {
      return 'Could not make $binary runnable: ${chmod.stderr}';
    }
    return null;
  }

  /// Removes a half-written `.part` an install that was killed left behind:
  /// one an hour old is no install still running.
  Future<void> _sweepLeftovers(Directory folder) async {
    final stale = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entry in folder.list()) {
      if (entry is! File || !entry.path.endsWith('.part')) continue;
      if ((await entry.lastModified()).isAfter(stale)) continue;
      try {
        await entry.delete();
      } on FileSystemException catch (error) {
        log.w('remove ${entry.path}', error);
      }
    }
  }

  /// Makes [name] in [folder] match [want]; answers the problem, or null.
  Future<String?> _ensure(
    Directory folder,
    String name,
    _Integrity want,
  ) async {
    final target = p.join(folder.path, name);
    if (await _matches(File(target), want)) return null;
    final asset = await readAsset('$_assets/$name.gz');
    if (asset == null) return 'This build is missing $name.';
    log.i('install $name into ${folder.path}');
    return Isolate.run(() => _unpack(asset, want, target));
  }

  /// Copies the private VC++ runtime next to the engine, each DLL checked
  /// against the runtime's own manifest.
  Future<String?> _windowsRuntime(Directory folder) async {
    final archive = Directory(
      p.join(appDirectory.path, 'data', 'bughouse-runtime'),
    );
    final file = File(p.join(archive.path, 'manifest.json'));
    if (!await file.exists()) {
      // A build made without the packaged copy (a developer's `flutter
      // run`) still has the DLLs the app itself loads beside its exe.
      log.w(
        'install the bughouse runtime',
        'no ${file.path}; copying the app’s',
      );
      await _copyAppRuntime(appDirectory, folder);
      return null;
    }
    final text = await file.readAsString();
    final names = _Manifest.namesIn(text).where(_isRuntimeDll).toList();
    final manifest = _Manifest.read(text, names);
    if (manifest == null || names.isEmpty) {
      return 'The Visual C++ runtime’s manifest is damaged; reinstall the app.';
    }
    for (final name in names) {
      final want = manifest.files[name]!;
      final target = p.join(folder.path, name);
      if (await _matches(File(target), want)) continue;
      final source = File(p.join(archive.path, '$name.gz'));
      final bytes = await source.readAsBytes();
      final problem = await Isolate.run(() => _unpack(bytes, want, target));
      if (problem != null) return problem;
    }
    return null;
  }
}

/// Copies each Visual C++ DLL beside the app in [app] into [folder] when
/// the copy there differs in size. The app has loaded these itself, so they
/// are the right architecture; a failure is a log line, and the engine then
/// finds the machine's own runtime, if any.
Future<void> _copyAppRuntime(Directory app, Directory folder) async {
  try {
    await for (final entry in app.list()) {
      final name = p.basename(entry.path);
      if (entry is! File || !_isRuntimeDll(name)) continue;
      final target = File(p.join(folder.path, name));
      if (await target.exists() &&
          await target.length() == await entry.length()) {
        continue;
      }
      _place(await entry.readAsBytes(), target.path);
    }
  } on FileSystemException catch (error) {
    log.w('copy the app’s Visual C++ runtime', error);
  }
}

/// A DLL of the Visual C++ runtime, by the names CMake deploys.
bool _isRuntimeDll(String name) {
  final lower = name.toLowerCase();
  final safe = !lower.contains(RegExp(r'[/\\:]')) && !lower.contains('..');
  return safe &&
      lower.endsWith('.dll') &&
      (lower.startsWith('msvcp140') ||
          lower.startsWith('vcruntime140') ||
          lower.startsWith('concrt140'));
}

/// Whether [file] is there with the size and hash promised. Hashed on its
/// own isolate and read in chunks: this runs before every launch, over
/// 80 MB.
Future<bool> _matches(File file, _Integrity want) {
  final path = file.path;
  return Isolate.run(() async {
    final found = File(path);
    if (!found.existsSync() || found.lengthSync() != want.bytes) return false;
    final digest = await sha256.bind(found.openRead()).first;
    return digest.toString() == want.sha256;
  });
}

/// Inflates [compressed] and checks it before it replaces [target]; runs in
/// its own isolate, since the network alone is 54 MB. Answers the problem,
/// or null. Named after this process, so two apps installing at once never
/// rename each other's half-written file into place.
String? _unpack(Uint8List compressed, _Integrity want, String target) {
  final payload = gzip.decode(compressed);
  final digest = sha256.convert(payload).toString();
  if (payload.length != want.bytes || digest != want.sha256) {
    return 'The bundled ${p.basename(target)} does not match its manifest.';
  }
  _place(payload, target);
  return null;
}

/// Writes [payload] as [target] under a name of this process's own, then
/// renames it into place, so no reader ever sees half a file.
void _place(List<int> payload, String target) {
  final partial = File('$target.$pid.part');
  try {
    partial.writeAsBytesSync(payload, flush: true);
    partial.renameSync(target);
  } finally {
    if (partial.existsSync()) partial.deleteSync();
  }
}

typedef _Integrity = ({int bytes, String sha256});

final class _Manifest {
  const _Manifest(this.files);

  final Map<String, _Integrity> files;

  /// Every name [json] has a record for.
  static Iterable<String> namesIn(String json) {
    try {
      final raw = jsonDecode(json);
      return raw is Map<String, Object?> ? raw.keys : const [];
    } on FormatException {
      return const [];
    }
  }

  /// The records for [names] in [json], or null when one is missing or
  /// malformed.
  static _Manifest? read(String json, List<String> names) {
    final Object? raw;
    try {
      raw = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (raw is! Map<String, Object?>) return null;
    final files = <String, _Integrity>{};
    for (final name in names) {
      final record = raw[name];
      if (record is! Map<String, Object?>) return null;
      final (bytes, sha) = (record['bytes'], record['sha256']);
      if (bytes is! int || bytes <= 0 || sha is! String) return null;
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) return null;
      files[name] = (bytes: bytes, sha256: sha.toLowerCase());
    }
    return _Manifest(files);
  }
}

const _assets = 'assets/bughouse';
const _model = 'hivemind.onnx';

String get _binaryName {
  if (Platform.isWindows) return 'hivemind-windows.exe';
  if (Platform.isMacOS) return 'hivemind-macos';
  return 'hivemind-linux';
}

String get _runtimeName {
  if (Platform.isWindows) return 'hivemind_ort.dll';
  if (Platform.isMacOS) return 'libonnxruntime.dylib';
  return 'libonnxruntime.so.1';
}
