import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Why the bughouse engine died before it printed anything, on Windows.
///
/// The engine runs as its own process out of the support directory, and the
/// Windows loader resolves its imports against a fixed list of places: the
/// engine's own directory, then System32, then the Windows directory, then the
/// working directory, then everything on `PATH`. Only the first of those is
/// ours. If any other one answers first with a file that is not a 64-bit
/// image — a 32-bit `MSVCP140.dll` left on `PATH` by some unrelated toolchain
/// is the classic — the loader stops the process before `main` with
/// `STATUS_INVALID_IMAGE_FORMAT`, and every symptom the app can see is a
/// process that started, said nothing and exited.
///
/// [BughouseEngine] narrows the search itself (it launches with the engine's
/// directory as the working directory and a `PATH` cut down to the engine
/// directory plus the system ones), so this is what explains the machines that
/// still fail: it walks the same order the loader does and names the file.
///
/// Deliberately free of any dependency on a live process, so the whole thing
/// is testable on a Linux CI box against a directory of fixtures.
class WindowsLoaderCheck {
  const WindowsLoaderCheck._();

  /// `IMAGE_FILE_MACHINE_AMD64` — the only machine we ship or can load.
  static const int amd64 = 0x8664;

  static const Map<int, String> _machineNames = {
    0x014c: '32-bit (x86)',
    0x8664: '64-bit (x64)',
    0xaa64: 'ARM64',
    0x01c4: '32-bit (ARM)',
    0x0200: 'Itanium',
  };

  /// Every library the shipped engine and its ONNX Runtime import that Windows
  /// does not itself guarantee, and so has to be found by search.
  ///
  /// `api-ms-win-*` are API sets the loader resolves through the OS schema,
  /// and KERNEL32/ADVAPI32 are KnownDLLs that can only ever come from System32;
  /// neither can be shadowed, so neither is listed. The rest can be, which is
  /// exactly why they are.
  ///
  /// Kept in step with `tools/test_bughouse_engine.py deps`, which reads the
  /// shipped binaries' real import tables and fails CI if they ever ask for
  /// something that is neither part of Windows nor shipped beside the engine.
  static const List<String> engineDependencies = [
    'onnxruntime.dll',
    'MSVCP140.dll',
    'MSVCP140_1.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
    'SETUPAPI.dll',
    'dbghelp.dll',
    'dxgi.dll',
  ];

  /// The subset the app is responsible for putting beside the engine, because
  /// it is not part of a clean Windows install. See
  /// `BughouseBundle.installWindowsRuntime`.
  static const List<String> appSuppliedDependencies = [
    'MSVCP140.dll',
    'MSVCP140_1.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
  ];

  /// The machine a PE image declares, or null when [head] is not a PE.
  ///
  /// Takes bytes rather than a path so a test can hand it a two-byte file and
  /// a truncated header without touching a disk.
  @visibleForTesting
  static int? peMachine(Uint8List head) {
    if (head.length < 0x40 || head[0] != 0x4D || head[1] != 0x5A) return null;
    final data = ByteData.sublistView(head);
    final peAt = data.getUint32(0x3C, Endian.little);
    if (peAt + 6 > head.length) return null;
    if (head[peAt] != 0x50 ||
        head[peAt + 1] != 0x45 ||
        head[peAt + 2] != 0 ||
        head[peAt + 3] != 0) {
      return null;
    }
    return data.getUint16(peAt + 4, Endian.little);
  }

  /// How to spell a machine value to a person.
  static String describeMachine(int? machine) => machine == null
      ? 'not a Windows program at all'
      : _machineNames[machine] ?? 'machine 0x${machine.toRadixString(16)}';

  /// The directories the loader tries, in its order, for a process whose image
  /// lives in [engineDir].
  ///
  /// Safe DLL search mode has been the default since Windows XP SP2, which is
  /// what puts the working directory after the system directories rather than
  /// second. [environment] is the *child's* environment, so passing the
  /// sanitised one shows what the engine actually searched and passing
  /// [Platform.environment] shows what it would have searched without the
  /// sanitising — which is the interesting question when reporting a failure.
  @visibleForTesting
  static List<String> searchOrder({
    required String engineDir,
    required Map<String, String> environment,
    String? workingDirectory,
  }) {
    final windows =
        environment['SystemRoot'] ?? environment['windir'] ?? r'C:\Windows';
    final path = environment.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'path',
          orElse: () => const MapEntry('PATH', ''),
        )
        .value;
    return [
      engineDir,
      p.join(windows, 'System32'),
      windows,
      if (workingDirectory != null) workingDirectory,
      for (final entry in path.split(';'))
        if (entry.trim().isNotEmpty) entry.trim(),
    ];
  }

  /// The machine of one file already on disk, or null when it is unreadable
  /// or not a PE image at all.
  static Future<int?> machineOfFile(File file) async {
    try {
      final handle = await file.open();
      try {
        return peMachine(await handle.read(0x400));
      } finally {
        await handle.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Where one dependency actually resolves, and what it turns out to be.
  static Future<DllResolution> resolve(String name, List<String> dirs) async {
    for (final dir in dirs) {
      final candidate = File(p.join(dir, name));
      if (!await candidate.exists()) continue;
      Uint8List head;
      try {
        final handle = await candidate.open();
        try {
          head = await handle.read(0x400);
        } finally {
          await handle.close();
        }
      } catch (_) {
        // Unreadable is as good as absent to us, and not worth failing over.
        continue;
      }
      return DllResolution(
        name: name,
        path: candidate.path,
        machine: peMachine(head),
      );
    }
    return DllResolution(name: name, path: null, machine: null);
  }

  /// Resolve every dependency, in the loader's own order.
  static Future<List<DllResolution>> resolveAll({
    required String engineDir,
    required Map<String, String> environment,
    String? workingDirectory,
    List<String> names = engineDependencies,
  }) async {
    final dirs = searchOrder(
      engineDir: engineDir,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return [for (final name in names) await resolve(name, dirs)];
  }

  /// What to tell the user, or null when nothing in [resolutions] is wrong.
  ///
  /// Wrong architecture first and by full path, because that is the finding
  /// they can act on: the fix is to move or remove that one file. A dependency
  /// that resolves nowhere at all is reported second, and only for the ones
  /// Windows does not ship, since those are the app's job to provide.
  static String? describe(List<DllResolution> resolutions) {
    final wrong = resolutions.where((r) => r.isWrongArchitecture).toList();
    final missing = resolutions
        .where((r) => r.isMissing && appSuppliedDependencies.contains(r.name))
        .toList();
    if (wrong.isEmpty && missing.isEmpty) return null;

    final buffer = StringBuffer();
    for (final r in wrong) {
      buffer.writeln(
        'The engine is 64-bit, but Windows loads ${r.name} from\n'
        '  ${r.path}\n'
        'and that copy is ${describeMachine(r.machine)}. Move or rename it, '
        'or take its folder off PATH.',
      );
    }
    if (missing.isNotEmpty) {
      buffer.writeln(
        '${missing.map((r) => r.name).join(', ')} could not be found anywhere. '
        'These come with the Microsoft Visual C++ Redistributable (x64); the '
        'app normally copies them beside the engine itself, so this also means '
        'that copy did not happen.',
      );
    }
    return buffer.toString().trimRight();
  }

  /// A full readout of where every dependency resolved, for a bug report.
  static String report(List<DllResolution> resolutions) {
    final lines = <String>[];
    for (final r in resolutions) {
      lines.add(
        r.isMissing
            ? '  ${r.name.padRight(22)} not found'
            : '  ${r.name.padRight(22)} ${describeMachine(r.machine)}  ${r.path}',
      );
    }
    return lines.join('\n');
  }
}

/// Where one library resolved for the engine's process, and what it is.
@immutable
class DllResolution {
  const DllResolution({
    required this.name,
    required this.path,
    required this.machine,
  });

  final String name;

  /// Full path of the first file the loader would have found, or null.
  final String? path;

  /// PE machine of that file; null when it is not a PE image at all.
  final int? machine;

  bool get isMissing => path == null;

  /// Present, but something the engine's process cannot load: a 32-bit or
  /// ARM64 build, or a file that is not a PE image (a truncated extraction).
  bool get isWrongArchitecture =>
      path != null && machine != WindowsLoaderCheck.amd64;

  @override
  String toString() =>
      '$name -> ${path ?? 'not found'} '
      '(${WindowsLoaderCheck.describeMachine(machine)})';
}
