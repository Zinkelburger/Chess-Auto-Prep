import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../utils/atomic_file.dart';
import '../../../services/storage/file_mutation_service.dart';
import 'update_release.dart';

/// Native installers own package-managed installs. A marked portable Linux
/// bundle can be exchanged as a directory, retaining the previous bundle.
class UpdateInstaller {
  UpdateInstaller({String? executable})
    : executable = executable ?? Platform.resolvedExecutable;
  final String executable;

  Future<InstallKind> detect() async {
    if (Abi.current() == Abi.windowsX64) {
      return await File(p.join(p.dirname(executable), 'unins000.exe')).exists()
          ? InstallKind.windowsInstaller
          : InstallKind.manual;
    }
    if (Abi.current() != Abi.linuxX64 ||
        Platform.environment.containsKey('FLATPAK_ID')) {
      return InstallKind.manual;
    }
    if (executable == '/opt/chess-auto-prep/chess_auto_prep') {
      if (!await _succeeds('sh', [
        '-c',
        'command -v pkexec && command -v flock && command -v sha256sum',
      ])) {
        return InstallKind.manual;
      }
      if (await _succeeds('dpkg-query', [
        '-W',
        '-f=\${Status}',
        'chess-auto-prep',
      ], contains: 'install ok installed')) {
        return InstallKind.linuxDeb;
      }
      if (await _succeeds('rpm', ['-q', 'chess-auto-prep'])) {
        return InstallKind.linuxRpm;
      }
      return InstallKind.manual;
    }
    final root = Directory(p.dirname(executable));
    final marker = File(p.join(root.path, '.chess-auto-prep-portable'));
    if (await marker.exists() &&
        await marker.readAsString() == '1\n' &&
        await _succeeds('sh', [
          '-c',
          'test -w "\$1" && test -w "\$2" && command -v unzip && command -v sha256sum && command -v flock',
          'updater',
          root.path,
          root.parent.path,
        ])) {
      return InstallKind.linuxPortable;
    }
    return InstallKind.manual;
  }

  Future<bool> _succeeds(
    String command,
    List<String> args, {
    String? contains,
  }) async {
    try {
      final result = await Process.run(
        command,
        args,
      ).timeout(const Duration(seconds: 10));
      return result.exitCode == 0 &&
          (contains == null || '${result.stdout}'.contains(contains));
    } catch (_) {
      return false;
    }
  }

  /// Schedules installation after a normal app close. Never kills the app or
  /// any engines. Helpers verify the payload again immediately before use.
  Future<File> schedule(
    File payload,
    UpdateRelease release,
    InstallKind kind,
  ) async {
    final dir = payload.parent;
    final armed = File(p.join(dir.path, 'install-requested'));
    await writeTextFileAtomically(armed, '1');
    try {
      if (kind == InstallKind.windowsInstaller) {
        final script = File(p.join(dir.path, 'install.ps1'));
        await writeTextFileAtomically(
          script,
          await rootBundle.loadString('assets/updater/install_windows.ps1'),
        );
        final config = File(p.join(dir.path, 'request.json'));
        await writeTextFileAtomically(
          config,
          jsonEncode({
            'processId': pid,
            'payload': payload.path,
            'sha256': release.sha256,
            'executable': executable,
            'armed': armed.path,
          }),
        );
        await Process.start('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-Request',
          config.path,
        ], mode: ProcessStartMode.detached);
      } else {
        final script = File(p.join(dir.path, 'install.sh'));
        await writeTextFileAtomically(
          script,
          await rootBundle.loadString('assets/updater/install_linux.sh'),
        );
        await Process.start('/bin/bash', [
          script.path,
          '$pid',
          payload.path,
          release.sha256,
          executable,
          kind.name,
          armed.path,
        ], mode: ProcessStartMode.detached);
      }
      // A detached spawn alone does not prove the helper started successfully.
      final ready = File(p.join(dir.path, 'helper-ready'));
      for (var i = 0; i < 50; i++) {
        if (await ready.exists()) return armed;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError(
        'Update helper did not start. See the update log in ${dir.path}.',
      );
    } catch (_) {
      await FileMutationService.instance.deleteDisposableFile(
        armed,
        allowedRoot: dir,
      );
      rethrow;
    }
  }
}
