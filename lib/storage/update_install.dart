import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'update_files.dart';

/// How this copy of the app was installed, which decides which release file
/// can replace it and who replaces it.
///
/// The Linux names are also the helper script's `kind` argument.
enum InstallKind {
  /// The Inno Setup installer; it upgrades in place.
  windowsSetup('windows-setup.exe'),
  linuxDeb('linux-amd64.deb'),
  linuxRpm('linux-x86_64.rpm'),

  /// The release zip, unpacked where the user can write, with its marker.
  linuxPortable('linux.zip'),

  /// Nothing the app can install itself: Flatpak, macOS, the Windows zip,
  /// an unmarked or read-only bundle, a development build. The user is sent
  /// to the release page.
  manual(null);

  const InstallKind(this.assetSuffix);

  /// The end of the release file's name, after `chess-auto-prep-<tag>-`.
  final String? assetSuffix;
}

/// Runs a short command and answers its result, or null when it could not
/// run, hung or crashed.
typedef CommandRunner =
    Future<ProcessResult?> Function(String command, List<String> arguments);

/// Starts the helper so that it outlives the app.
typedef DetachedStart =
    Future<void> Function(String executable, List<String> arguments);

/// The helper's command line: what to run and its arguments, which are data
/// the scripts never evaluate.
typedef HelperLaunch = ({String executable, List<String> arguments});

/// The command that starts [kind]'s helper script at [script]. On Windows
/// the details travel in the JSON file at [request] ([helperRequest]), so
/// that a path in any script or code page arrives intact.
HelperLaunch helperLaunch(
  InstallKind kind, {
  required String script,
  required String request,
  required int appPid,
  required VerifiedPayload payload,
  required String executable,
  required String armed,
}) => switch (kind) {
  InstallKind.windowsSetup => (
    executable: 'powershell.exe',
    arguments: [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script,
      '-Request',
      request,
    ],
  ),
  InstallKind.linuxDeb || InstallKind.linuxRpm || InstallKind.linuxPortable => (
    executable: '/bin/bash',
    arguments: [
      script,
      '$appPid',
      payload.path,
      payload.sha256,
      executable,
      kind.name,
      armed,
    ],
  ),
  InstallKind.manual => throw ArgumentError('a manual install has no helper'),
};

/// The Windows helper's request file.
Map<String, Object> helperRequest({
  required int appPid,
  required VerifiedPayload payload,
  required String executable,
  required String armed,
}) => {
  'processId': appPid,
  'payload': payload.path,
  'sha256': payload.sha256,
  'executable': executable,
  'armed': armed,
};

sealed class HelperStart {
  const HelperStart();
}

/// The helper is running and waits for the app to close. Deleting [armed]
/// cancels it.
final class HelperArmed extends HelperStart {
  const HelperArmed(this.armed);

  final String armed;
}

final class HelperNotStarted extends HelperStart {
  const HelperNotStarted();
}

/// A helper, of this copy or another, still holds the install lock; a
/// second one would only fail, so none was started.
final class HelperBusy extends HelperStart {
  const HelperBusy();
}

/// Tells how the app was installed and hands a verified file to the helper
/// script in `assets/updater/` that swaps it in after the app closes. The
/// helper checks the SHA-256 again just before it installs, never kills the
/// app, and writes `last-error.txt` in the updates folder when it fails.
/// It opens the app again only when asked to ([setReopen]): closing the app
/// for the day installs and leaves it closed.
///
/// Package installs are left to their package manager (`pkexec dpkg` or
/// `rpm`) and the Windows installer; a marked portable Linux bundle is
/// exchanged as a folder, keeping the previous one beside it.
///
/// Every helper holds `install.lock` in the updates folder while it runs
/// (`flock` on Linux, an unshared handle on Windows). That lock, not the
/// ready file, says whether a helper is alive: a helper that was killed
/// leaves its ready file behind.
final class UpdateInstaller {
  UpdateInstaller({
    required this.readHelper,
    String? executable,
    Map<String, String>? environment,
    Abi? abi,
    int? appPid,
    this.run = runBriefly,
    this.startDetached = _startDetached,
    this.readyPoll = const Duration(milliseconds: 100),
    this.readyPolls = 50,
  }) : executable = executable ?? Platform.resolvedExecutable,
       environment = environment ?? Platform.environment,
       abi = abi ?? Abi.current(),
       appPid = appPid ?? pid;

  /// The text of a bundled helper script.
  final Future<String> Function(String asset) readHelper;
  final String executable;
  final Map<String, String> environment;
  final Abi abi;
  final int appPid;
  final CommandRunner run;
  final DetachedStart startDetached;
  final Duration readyPoll;
  final int readyPolls;

  static const packagedExecutable = '/opt/chess-auto-prep/chess_auto_prep';
  static const portableMarker = '.chess-auto-prep-portable';
  static const _package = 'chess-auto-prep';
  static const _windowsUninstaller = 'unins000.exe';
  static const _lockName = 'install.lock';

  Future<InstallKind> detect() async {
    try {
      if (abi == Abi.windowsX64) {
        final uninstaller = p.join(p.dirname(executable), _windowsUninstaller);
        return await File(uninstaller).exists()
            ? InstallKind.windowsSetup
            : InstallKind.manual;
      }
      if (abi != Abi.linuxX64 || environment.containsKey('FLATPAK_ID')) {
        return InstallKind.manual;
      }
      if (executable == packagedExecutable) return await _linuxPackage();
      return await _writablePortable()
          ? InstallKind.linuxPortable
          : InstallKind.manual;
    } on Object catch (error) {
      log.w('tell how the app was installed', error);
      return InstallKind.manual;
    }
  }

  /// Which package manager owns `/opt/chess-auto-prep`, when the tools the
  /// helper needs are there.
  Future<InstallKind> _linuxPackage() async {
    if (!await _succeeds('sh', [
      '-c',
      'command -v pkexec && command -v flock && command -v sha256sum',
    ])) {
      return InstallKind.manual;
    }
    final dpkg = await run('dpkg-query', ['-W', r'-f=${Status}', _package]);
    if (dpkg != null &&
        dpkg.exitCode == 0 &&
        '${dpkg.stdout}'.contains('install ok installed')) {
      return InstallKind.linuxDeb;
    }
    if (await _succeeds('rpm', ['-q', _package])) return InstallKind.linuxRpm;
    return InstallKind.manual;
  }

  /// A bundle carrying the release zip's marker, whose folder and parent
  /// the helper can write, with the tools it needs.
  Future<bool> _writablePortable() async {
    final root = p.dirname(executable);
    final marker = File(p.join(root, portableMarker));
    if (!await marker.exists() || await marker.readAsString() != '1\n') {
      return false;
    }
    return _succeeds('sh', [
      '-c',
      r'test -w "$1" && test -w "$2" && command -v unzip && command -v sha256sum && command -v flock',
      'updater',
      root,
      p.dirname(root),
    ]);
  }

  Future<bool> _succeeds(String command, List<String> arguments) async =>
      (await run(command, arguments))?.exitCode == 0;

  /// Arms the helper for [payload]: it waits for this process to end, then
  /// installs. Returns once the helper says it is running. Nothing is
  /// started while another helper still runs; a ready file no running
  /// helper wrote is removed first, so only this helper's counts.
  Future<HelperStart> schedule(
    VerifiedPayload payload,
    InstallKind kind,
  ) async {
    final folder = payload.folder;
    final armed = File(p.join(folder, armedName));
    final windows = kind == InstallKind.windowsSetup;
    final script = File(p.join(folder, windows ? 'install.ps1' : 'install.sh'));
    final request = File(p.join(folder, 'request.json'));
    if (await helperRunning(p.dirname(folder))) {
      log.w('start the update helper', 'another one is still running');
      return const HelperBusy();
    }
    try {
      await _removeReady(folder);
      await _remove(p.join(folder, reopenName));
      await armed.writeAsString('1', flush: true);
      await script.writeAsString(
        await readHelper(
          windows
              ? 'assets/updater/install_windows.ps1'
              : 'assets/updater/install_linux.sh',
        ),
        flush: true,
      );
      if (windows) {
        await request.writeAsString(
          jsonEncode(
            helperRequest(
              appPid: appPid,
              payload: payload,
              executable: executable,
              armed: armed.path,
            ),
          ),
          flush: true,
        );
      }
      final launch = helperLaunch(
        kind,
        script: script.path,
        request: request.path,
        appPid: appPid,
        payload: payload,
        executable: executable,
        armed: armed.path,
      );
      await startDetached(launch.executable, launch.arguments);
      if (await _helperReady(folder, ready: true)) {
        return HelperArmed(armed.path);
      }
      log.w('start the update helper', 'no ready signal; see $folder');
    } on Object catch (error) {
      log.w('start the update helper', error);
    }
    await _disarm(armed.path);
    return const HelperNotStarted();
  }

  /// Disarms the helper and waits for it to notice; false when it is still
  /// running afterwards, so it must not be armed again yet. A ready file
  /// that outlives every helper was left by a killed one and is removed.
  Future<bool> cancel(String armed) async {
    await _disarm(armed);
    final folder = p.dirname(armed);
    if (await _helperReady(folder, ready: false)) return true;
    if (await helperRunning(p.dirname(folder))) return false;
    try {
      await _removeReady(folder);
      return true;
    } on Object catch (error) {
      log.w('cancel the update install', error);
      return false;
    }
  }

  /// Tells the helper armed by [armed] whether to open the app again once
  /// it has installed. False when that could not be written.
  Future<bool> setReopen(String armed, {required bool reopen}) async {
    final marker = File(p.join(p.dirname(armed), reopenName));
    try {
      if (reopen) {
        await marker.writeAsString('1', flush: true);
      } else {
        await _remove(marker.path);
      }
      return true;
    } on Object catch (error) {
      log.w('ask the update helper to reopen the app', error);
      return false;
    }
  }

  /// Whether a helper holds the install lock in [updates], the updates
  /// folder. When that cannot be told, a helper is taken to be running,
  /// so nothing is armed over it.
  Future<bool> helperRunning(String updates) async {
    final lock = File(p.join(updates, _lockName));
    if (abi == Abi.windowsX64) {
      if (!await lock.exists()) return false;
      try {
        await (await lock.open()).close();
        return false;
      } on FileSystemException {
        return true;
      }
    }
    final probe = await run('flock', ['-n', lock.path, 'true']);
    return probe == null || probe.exitCode != 0;
  }

  /// Waits until the helper's ready file is there (or gone), up to five
  /// seconds: a detached start alone does not prove the script is running.
  Future<bool> _helperReady(String folder, {required bool ready}) async {
    final file = File(p.join(folder, helperReadyName));
    for (var i = 0; i < readyPolls; i++) {
      if (await file.exists() == ready) return true;
      await Future<void>.delayed(readyPoll);
    }
    return await file.exists() == ready;
  }

  /// Removes a ready file no running helper owns; throws when it cannot,
  /// since it would then pass for the next helper's.
  static Future<void> _removeReady(String folder) =>
      _remove(p.join(folder, helperReadyName));

  static Future<void> _disarm(String armed) async {
    try {
      await _remove(armed);
    } on Object catch (error) {
      log.w('cancel the update install', error);
    }
  }

  static Future<void> _remove(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

/// How long a short command may take before it is stopped.
const _commandTimeout = Duration(seconds: 10);

/// Runs [command] and answers its result; null when it is not installed,
/// failed to run, or took longer than [timeout] — then it is killed, so a
/// hung package manager is not left behind.
Future<ProcessResult?> runBriefly(
  String command,
  List<String> arguments, {
  Duration timeout = _commandTimeout,
}) async {
  final Process process;
  try {
    process = await Process.start(command, arguments);
  } on ProcessException catch (error) {
    log.i('$command is not available for updates: ${error.message}');
    return null;
  }
  final stdout = process.stdout.transform(systemEncoding.decoder).join();
  final stderr = process.stderr.transform(systemEncoding.decoder).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return ProcessResult(process.pid, code, await stdout, await stderr);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    log.w('ask $command about the install', 'no answer in $timeout; killed');
  } on Object catch (error) {
    log.w('ask $command about the install', error);
  }
  stdout.ignore();
  stderr.ignore();
  return null;
}

Future<void> _startDetached(String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}
