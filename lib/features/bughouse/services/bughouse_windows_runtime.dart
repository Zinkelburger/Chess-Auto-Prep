import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/file_mutation_service.dart';
import '../../../utils/atomic_file.dart';
import 'windows_loader_check.dart';

/// The engine's private VC++ runtime, shared by setup and portable installs.
/// Expected bytes come from the build's manifest, never a possibly damaged
/// app-local or system DLL. Only files in the private engine folder are repaired.
class BughouseWindowsRuntime {
  static Directory archiveDirectory(Directory app) =>
      Directory(p.join(app.path, 'data', 'bughouse-runtime'));

  static bool isRuntime(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.dll') &&
        (lower.startsWith('msvcp140') ||
            lower.startsWith('vcruntime140') ||
            lower.startsWith('concrt140'));
  }

  static Future<Map<String, ({int bytes, String hash})>> readManifest(
    Directory archive,
  ) async {
    final file = File(p.join(archive.path, 'manifest.json'));
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final manifest = <String, ({int bytes, String hash})>{};
    for (final entry in raw.entries) {
      final name = entry.key;
      if (!isRuntime(name) ||
          name != name.toLowerCase() ||
          name.contains('/') ||
          name.contains(r'\') ||
          name.contains(':') ||
          name.contains('..')) {
        throw FormatException('Invalid DLL name in ${file.path}: $name');
      }
      final value = entry.value as Map<String, dynamic>;
      final bytes = value['bytes'] as int;
      final hash = value['sha256'] as String;
      if (bytes < 64 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw FormatException(
          'Invalid integrity record for $name in ${file.path}',
        );
      }
      manifest[name] = (bytes: bytes, hash: hash);
    }
    for (final name in WindowsLoaderCheck.appSuppliedDependencies) {
      if (!manifest.containsKey(name.toLowerCase())) {
        throw FormatException('Missing $name in ${file.path}');
      }
    }
    return manifest;
  }

  /// Every actual process launch rehashes these small DLLs. A mismatch is
  /// repaired from the archive only after its size, digest and x64 header pass.
  static Future<List<String>> ensureInstalled({
    required Directory archive,
    required Directory target,
  }) async {
    final lines = <String>[
      'VC++ archive: ${archive.path}',
      'Engine folder: ${target.path}',
    ];
    try {
      final manifest = await readManifest(archive);
      await target.create(recursive: true);
      for (final entry in manifest.entries) {
        final name = entry.key;
        final expected = entry.value;
        final file = File(p.join(target.path, name));
        final actual = await digest(file);
        lines.add(
          '$name: SHA-256 ${actual ?? '(missing)'}, expected ${expected.hash}',
        );
        if (actual == expected.hash) {
          await requireX64(file);
          continue;
        }
        final source = File(p.join(archive.path, '$name.gz'));
        final bytes = gzip.decode(await source.readAsBytes());
        final sourceHash = sha256.convert(bytes).toString();
        if (bytes.length != expected.bytes || sourceHash != expected.hash) {
          throw FileSystemException(
            'Bundled DLL mismatch: ${bytes.length} bytes, SHA-256 $sourceHash; '
            'expected ${expected.bytes} bytes, SHA-256 ${expected.hash}',
            source.path,
          );
        }
        final machine = WindowsLoaderCheck.peMachine(Uint8List.fromList(bytes));
        if (machine != WindowsLoaderCheck.amd64) {
          throw FileSystemException(
            'Expected x64 PE image; ${WindowsLoaderCheck.describeMachine(machine)}',
            source.path,
          );
        }
        await AtomicFileWriter().writeBytes(file, bytes);
        if (await digest(file) != expected.hash) {
          throw FileSystemException(
            'Installed DLL failed SHA-256 verification',
            file.path,
          );
        }
        lines.add('$name: replaced and verified');
      }
      // Extra old VC++ copies may be transitive dependencies. Do not silently
      // allow them to override the runtime shipped in this build.
      await for (final file in target.list(followLinks: false)) {
        final name = p.basename(file.path).toLowerCase();
        if (file is File && isRuntime(name) && !manifest.containsKey(name)) {
          await FileMutationService.instance.deleteDisposableFile(
            file,
            allowedRoot: target,
          );
          lines.add('$name: removed obsolete engine-local DLL');
        }
      }
      return lines;
    } catch (e) {
      lines.add('Dependency verification failed: $e');
      throw BughouseRuntimeFailure('$e', lines);
    }
  }

  static Future<String?> digest(File file) async {
    if (!await file.exists()) return null;
    return (await sha256.bind(file.openRead()).first).toString();
  }

  static Future<void> requireX64(File file) async {
    final machine = await WindowsLoaderCheck.machineOfFile(file);
    if (machine != WindowsLoaderCheck.amd64) {
      throw FileSystemException(
        'Expected x64 PE image; ${WindowsLoaderCheck.describeMachine(machine)}',
        file.path,
      );
    }
  }
}

class BughouseRuntimeFailure implements Exception {
  BughouseRuntimeFailure(this.message, this.lines);
  final String message;
  final List<String> lines;
  @override
  String toString() => message;
}
