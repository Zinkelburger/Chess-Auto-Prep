import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// Where the installed engine and its net are, and the folder they are in:
/// the engine is started there.
typedef HypeBeastFiles = ({String executable, String net, String directory});

sealed class HypeBeastLocation {
  const HypeBeastLocation();
}

final class HypeBeastReady extends HypeBeastLocation {
  const HypeBeastReady(this.files);

  final HypeBeastFiles files;
}

final class HypeBeastMissing extends HypeBeastLocation {
  const HypeBeastMissing(this.reason);

  /// A sentence for the user.
  final String reason;
}

/// Puts HypeBeast, the bughouse engine, where it can run: the engine and
/// Fairy-Stockfish's bughouse net, shipped gzipped under `assets/bughouse/`
/// beside a `manifest.json` of each extracted file's size and SHA-256. The
/// engine is a static build (MinGW on Windows) and needs no library beside
/// it.
///
/// Every file is checked against the manifest before every launch, not only
/// the first: a file cut short by a killed install, or damaged on the disk,
/// keeps its name and would otherwise be trusted for ever. A file that does
/// not match is written again from the asset, under a temporary name and
/// checked before it replaces anything.
///
/// The folder was Hivemind's before: its engine, ONNX Runtime, network and
/// Windows runtime copies are removed on install, by their exact names.
///
/// HypeBeast is a Fairy-Stockfish fork under the GNU GPL version 3 or later;
/// its notice is bundled at `assets/licenses/HYPEBEAST_LICENSE.txt` and the
/// net's at `assets/licenses/BUGHOUSE_NNUE_NOTICE.txt`.
final class HypeBeastInstall {
  HypeBeastInstall({required this.supportDirectory, required this.readAsset});

  final Directory supportDirectory;

  /// Reads a bundled asset, or null when the build has none by that name.
  final Future<Uint8List?> Function(String asset) readAsset;

  /// Whether a build whose assets are [assetKeys] carries an engine for this
  /// platform: both files and the manifest they are checked against. The
  /// bughouse assets are fetched by `tools/fetch_assets.py`, not kept in
  /// git, so a build without them is ordinary and hides the mode.
  static bool bundledIn(Iterable<String> assetKeys) {
    final keys = assetKeys.toSet();
    return [
      for (final name in installedNames) '$_assets/$name.gz',
      '$_assets/manifest.json',
    ].every(keys.contains);
  }

  /// The two files, by the names they are installed under.
  static List<String> get installedNames => [_binaryName, net];

  /// The net's file name. Fairy-Stockfish takes a net for the variant whose
  /// name starts the file's, so it must stay `bughouse-…`.
  static const net = 'bughouse-cd8cceab93fe.nnue';

  /// What Hivemind, the engine this folder held before, left in it.
  static const formerFiles = {
    'hivemind-linux',
    'hivemind-macos',
    'hivemind-windows.exe',
    'hivemind.onnx',
    'libonnxruntime.so.1',
    'libonnxruntime.dylib',
    'hivemind_ort.dll',
    'msvcp140.dll',
    'msvcp140_1.dll',
    'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll',
    'msvcp140_codecvt_ids.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'concrt140.dll',
  };

  /// The look, and install if needed, in flight for each support folder.
  ///
  /// Every launch makes its own [HypeBeastInstall], and two launches during
  /// a first install would write one partial file, one renaming it into
  /// place while the other was still writing it. A launch that finds one in
  /// flight shares its answer; another process names its partial files
  /// after its own [pid].
  static final _locating = <String, Future<HypeBeastLocation>>{};

  Future<HypeBeastLocation> locate() {
    final key = p.normalize(p.absolute(supportDirectory.path));
    // `remove` hands back this same future, which the callback must not
    // return: `whenComplete` would wait for it and never finish.
    return _locating[key] ??= _locate().whenComplete(
      () => _locating.remove(key)?.ignore(),
    );
  }

  Future<HypeBeastLocation> _locate() async {
    final bytes = await readAsset('$_assets/manifest.json');
    if (bytes == null) {
      return const HypeBeastMissing('This build has no bughouse engine.');
    }
    final manifest = _Manifest.read(utf8.decode(bytes), installedNames);
    if (manifest == null) {
      log.e('read $_assets/manifest.json', 'a file has no size or SHA-256');
      return const HypeBeastMissing(
        'The bughouse engine’s manifest is damaged; reinstall the app.',
      );
    }
    final folder = Directory(p.join(supportDirectory.path, 'bughouse'));
    try {
      final problem = await _installAll(folder, manifest);
      if (problem != null) {
        log.e('install the bughouse engine', problem);
        return HypeBeastMissing(problem);
      }
    } on Object catch (error) {
      log.e('install the bughouse engine', error);
      return const HypeBeastMissing('Could not install the bughouse engine.');
    }
    return HypeBeastReady((
      executable: p.join(folder.path, _binaryName),
      net: p.join(folder.path, net),
      directory: folder.path,
    ));
  }

  /// Every file in [folder] as [manifest] promises it; answers the first
  /// problem, or null.
  Future<String?> _installAll(Directory folder, _Manifest manifest) async {
    await folder.create(recursive: true);
    await _sweep(folder);
    for (final name in installedNames) {
      final problem = await _ensure(folder, name, manifest.files[name]!);
      if (problem != null) return problem;
    }
    if (Platform.isWindows) return null;
    final binary = p.join(folder.path, _binaryName);
    final chmod = await Process.run('chmod', ['+x', binary]);
    if (chmod.exitCode != 0) {
      return 'Could not make $binary runnable: ${chmod.stderr}';
    }
    return null;
  }

  /// Removes what Hivemind left ([formerFiles]) and a half-written `.part`
  /// an install that was killed left behind: one an hour old is no install
  /// still running. A sweep that fails never fails the install.
  Future<void> _sweep(Directory folder) async {
    final stale = DateTime.now().subtract(const Duration(hours: 1));
    try {
      await for (final entry in folder.list()) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (formerFiles.contains(name.toLowerCase())) {
          await _remove(entry);
        } else if (name.endsWith('.part')) {
          await removeStaleLeftover(entry, stale);
        }
      }
    } on FileSystemException catch (error) {
      log.w('sweep ${folder.path}', error);
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
    return _unpackElsewhere(asset, want, target);
  }
}

Future<void> _remove(File file) async {
  try {
    await file.delete();
    log.i('remove ${file.path}, left by the former bughouse engine');
  } on FileSystemException catch (error) {
    log.w('remove ${file.path}', error);
  }
}

/// Whether [file] is there with the size and hash promised. Hashed on its
/// own isolate and read in chunks: this runs before every launch, over
/// 60 MB.
Future<bool> _matches(File file, _Integrity want) {
  final path = file.path;
  return Isolate.run(() async {
    final found = File(path);
    if (!found.existsSync() || found.lengthSync() != want.bytes) return false;
    final digest = await sha256.bind(found.openRead()).first;
    return digest.toString() == want.sha256;
  });
}

/// [_unpack] on another isolate. Top level, so the closure sent carries
/// only these values, never the installer.
Future<String?> _unpackElsewhere(
  Uint8List compressed,
  _Integrity want,
  String target,
) => Isolate.run(() => _unpack(compressed, want, target));

/// Inflates [compressed] and checks it before it replaces [target]; runs in
/// its own isolate, since the net alone is 58 MB. Answers the problem, or
/// null. Named after this process, so two apps installing at once never
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

String get _binaryName {
  if (Platform.isWindows) return 'hypebeast-windows.exe';
  if (Platform.isMacOS) return 'hypebeast-macos';
  return 'hypebeast-linux';
}

/// Deletes [entry] when it was last written before [stale]. Another copy
/// of the app may rename its own `.part` into place at any moment, so a
/// file gone before it is looked at is skipped, not an error.
Future<void> removeStaleLeftover(File entry, DateTime stale) async {
  try {
    if ((await entry.lastModified()).isAfter(stale)) return;
    await entry.delete();
  } on FileSystemException catch (error) {
    log.w('remove ${entry.path}', error);
  }
}
