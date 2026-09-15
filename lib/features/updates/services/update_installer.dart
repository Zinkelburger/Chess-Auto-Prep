/// Detects how this copy of the app was installed and hands a verified
/// payload to the platform helper script that swaps it in after the app
/// closes.
///
/// Native installers own package-managed installs. A marked portable Linux
/// bundle can be exchanged as a directory, retaining the previous bundle.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/file_mutation_service.dart';
import '../../../utils/atomic_file.dart';
import 'update_release.dart';

class UpdateInstaller {
  UpdateInstaller({String? executable})
    : executable = executable ?? Platform.resolvedExecutable;

  final String executable;

  /// Written by the helper once it is running; its presence means the
  /// install is armed. The helper removes it when the install is cancelled.
  static const helperReadyFileName = 'helper-ready';

  /// Written beside the payload while an install is requested; deleting it
  /// cancels the helper.
  static const armedFileName = 'install-requested';

  static const _windowsUninstaller = 'unins000.exe';
  static const _linuxPackagedExecutable =
      '/opt/chess-auto-prep/chess_auto_prep';
  static const _linuxPackageName = 'chess-auto-prep';
  static const _portableMarkerFileName = '.chess-auto-prep-portable';
  static const _portableMarkerContent = '1\n';
  static const _windowsHelperAsset = 'assets/updater/install_windows.ps1';
  static const _linuxHelperAsset = 'assets/updater/install_linux.sh';

  static const _commandTimeout = Duration(seconds: 10);
  static const _helperStartPoll = Duration(milliseconds: 100);
  static const _helperStartPolls = 50;

  Future<InstallKind> detect() async {
    if (Abi.current() == Abi.windowsX64) return _detectWindows();
    if (Abi.current() != Abi.linuxX64 ||
        Platform.environment.containsKey('FLATPAK_ID')) {
      return InstallKind.manual;
    }
    if (executable == _linuxPackagedExecutable) return _detectLinuxPackage();
    return await _isWritablePortableBundle()
        ? InstallKind.linuxPortable
        : InstallKind.manual;
  }

  /// An Inno Setup install leaves its uninstaller beside the executable.
  Future<InstallKind> _detectWindows() async =>
      await File(p.join(p.dirname(executable), _windowsUninstaller)).exists()
      ? InstallKind.windowsInstaller
      : InstallKind.manual;

  /// Which package manager owns the `/opt` install, if the tools the helper
  /// needs are present.
  Future<InstallKind> _detectLinuxPackage() async {
    if (!await _succeeds('sh', [
      '-c',
      'command -v pkexec && command -v flock && command -v sha256sum',
    ])) {
      return InstallKind.manual;
    }
    if (await _succeeds('dpkg-query', [
      '-W',
      '-f=\${Status}',
      _linuxPackageName,
    ], contains: 'install ok installed')) {
      return InstallKind.linuxDeb;
    }
    if (await _succeeds('rpm', ['-q', _linuxPackageName])) {
      return InstallKind.linuxRpm;
    }
    return InstallKind.manual;
  }

  /// A bundle marked portable whose directory and parent the helper can
  /// write, with the tools it needs on the path.
  Future<bool> _isWritablePortableBundle() async {
    final root = Directory(p.dirname(executable));
    final marker = File(p.join(root.path, _portableMarkerFileName));
    if (!await marker.exists()) return false;
    if (await marker.readAsString() != _portableMarkerContent) return false;
    return _succeeds('sh', [
      '-c',
      'test -w "\$1" && test -w "\$2" && command -v unzip && command -v sha256sum && command -v flock',
      'updater',
      root.path,
      root.parent.path,
    ]);
  }

  /// Whether [command] exits 0 (and prints [contains], when given). A
  /// command that is missing, hangs or crashes simply answers no.
  Future<bool> _succeeds(
    String command,
    List<String> args, {
    String? contains,
  }) async {
    try {
      final result = await Process.run(command, args).timeout(_commandTimeout);
      return result.exitCode == 0 &&
          (contains == null || '${result.stdout}'.contains(contains));
    } catch (_) {
      return false;
    }
  }

  /// Schedules installation after a normal app close. Never kills the app or
  /// any engines. Helpers verify the payload again immediately before use.
  ///
  /// Returns the armed marker; deleting it cancels the install. Throws
  /// [StateError] when the helper does not report itself running.
  Future<File> schedule(
    File payload,
    UpdateRelease release,
    InstallKind kind,
  ) async {
    final dir = payload.parent;
    final armed = File(p.join(dir.path, armedFileName));
    await writeTextFileAtomically(armed, '1');
    try {
      if (kind == InstallKind.windowsInstaller) {
        await _startWindowsHelper(dir, payload, release, armed);
      } else {
        await _startLinuxHelper(dir, payload, release, kind, armed);
      }
      await _awaitHelperReady(dir);
      return armed;
    } catch (_) {
      await FileMutationService.instance.deleteDisposableFile(
        armed,
        allowedRoot: dir,
      );
      rethrow;
    }
  }

  Future<void> _startWindowsHelper(
    Directory dir,
    File payload,
    UpdateRelease release,
    File armed,
  ) async {
    final script = File(p.join(dir.path, 'install.ps1'));
    await writeTextFileAtomically(
      script,
      await rootBundle.loadString(_windowsHelperAsset),
    );
    final request = File(p.join(dir.path, 'request.json'));
    await writeTextFileAtomically(
      request,
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
      request.path,
    ], mode: ProcessStartMode.detached);
  }

  Future<void> _startLinuxHelper(
    Directory dir,
    File payload,
    UpdateRelease release,
    InstallKind kind,
    File armed,
  ) async {
    final script = File(p.join(dir.path, 'install.sh'));
    await writeTextFileAtomically(
      script,
      await rootBundle.loadString(_linuxHelperAsset),
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

  /// A detached spawn alone does not prove the helper started successfully;
  /// wait for it to write its ready marker.
  Future<void> _awaitHelperReady(Directory dir) async {
    final ready = File(p.join(dir.path, helperReadyFileName));
    for (var i = 0; i < _helperStartPolls; i++) {
      if (await ready.exists()) return;
      await Future<void>.delayed(_helperStartPoll);
    }
    throw StateError(
      'Update helper did not start. See the update log in ${dir.path}.',
    );
  }
}
