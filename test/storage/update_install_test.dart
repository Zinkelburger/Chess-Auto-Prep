import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:chess_auto_prep/storage/update_files.dart';
import 'package:chess_auto_prep/storage/update_install.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_releases.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('update install é '));
  tearDown(() => root.deleteSync(recursive: true));

  const payload = VerifiedPayload('/cache/updates/v1.17.0-x/app.zip', 'ab12');

  group('helper command', () {
    test('Linux helpers get the positional arguments the script reads', () {
      for (final kind in [
        InstallKind.linuxDeb,
        InstallKind.linuxRpm,
        InstallKind.linuxPortable,
      ]) {
        final launch = helperLaunch(
          kind,
          script: '/cache/updates/v1.17.0-x/install.sh',
          request: '/unused',
          appPid: 42,
          payload: payload,
          executable: '/opt/chess-auto-prep/chess_auto_prep',
          armed: '/cache/updates/v1.17.0-x/install-requested',
        );
        // install_linux.sh: app_pid payload expected executable kind armed.
        expect(launch.executable, '/bin/bash');
        expect(launch.arguments, [
          '/cache/updates/v1.17.0-x/install.sh',
          '42',
          payload.path,
          'ab12',
          '/opt/chess-auto-prep/chess_auto_prep',
          kind.name,
          '/cache/updates/v1.17.0-x/install-requested',
        ]);
      }
    });

    test('the Windows helper reads one request file with the fields '
        'install_windows.ps1 uses', () {
      final launch = helperLaunch(
        InstallKind.windowsSetup,
        script: r'C:\cache\install.ps1',
        request: r'C:\cache\request.json',
        appPid: 7,
        payload: payload,
        executable: r'C:\Program Files\Chess Auto Prep\chess_auto_prep.exe',
        armed: r'C:\cache\install-requested',
      );
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        r'C:\cache\install.ps1',
        '-Request',
        r'C:\cache\request.json',
      ]);
      final request = helperRequest(
        appPid: 7,
        payload: payload,
        executable: r'C:\Program Files\Chess Auto Prep\chess_auto_prep.exe',
        armed: r'C:\cache\install-requested',
      );
      final script = File(
        'assets/updater/install_windows.ps1',
      ).readAsStringSync();
      for (final field in request.keys) {
        expect(script, contains('\$config.$field'), reason: field);
      }
      expect(request['sha256'], 'ab12');
    });

    test('the Linux script handles every kind the app arms it for', () {
      final script = File('assets/updater/install_linux.sh').readAsStringSync();
      for (final kind in [
        InstallKind.linuxDeb,
        InstallKind.linuxRpm,
        InstallKind.linuxPortable,
      ]) {
        expect(script, contains('${kind.name})'), reason: kind.name);
      }
    });
  });

  group('how the app was installed', () {
    UpdateInstaller installer({
      required String executable,
      Abi abi = Abi.linuxX64,
      Map<String, String> environment = const {},
      bool dpkgInstalled = false,
    }) => UpdateInstaller(
      readHelper: (_) async => '',
      executable: executable,
      environment: environment,
      abi: abi,
      run: (command, arguments) async => ProcessResult(
        0,
        command == 'rpm' ? 1 : 0,
        dpkgInstalled ? 'install ok installed' : '',
        '',
      ),
    );

    test('Windows setup leaves an uninstaller; the zip does not', () async {
      final exe = p.join(root.path, 'chess_auto_prep.exe');
      expect(
        await installer(executable: exe, abi: Abi.windowsX64).detect(),
        InstallKind.manual,
      );
      File(p.join(root.path, 'unins000.exe')).writeAsStringSync('');
      expect(
        await installer(executable: exe, abi: Abi.windowsX64).detect(),
        InstallKind.windowsSetup,
      );
    });

    test(
      'a marked portable bundle updates itself, unless it is a Flatpak',
      () async {
        final exe = p.join(root.path, 'chess_auto_prep');
        expect(await installer(executable: exe).detect(), InstallKind.manual);
        File(
          p.join(root.path, UpdateInstaller.portableMarker),
        ).writeAsStringSync('1\n');
        expect(
          await installer(executable: exe).detect(),
          InstallKind.linuxPortable,
        );
        expect(
          await installer(
            executable: exe,
            environment: const {'FLATPAK_ID': 'com.example.chess_auto_prep'},
          ).detect(),
          InstallKind.manual,
        );
      },
    );

    test('macOS always updates by hand', () async {
      expect(
        await installer(
          executable: '/Applications/x.app/Contents/MacOS/x',
          abi: Abi.macosArm64,
        ).detect(),
        InstallKind.manual,
      );
    });

    test(
      'the /opt install is the deb when dpkg owns it, else the rpm',
      () async {
        expect(
          await installer(
            executable: UpdateInstaller.packagedExecutable,
            dpkgInstalled: true,
          ).detect(),
          InstallKind.linuxDeb,
        );
        final rpm = UpdateInstaller(
          readHelper: (_) async => '',
          executable: UpdateInstaller.packagedExecutable,
          environment: const {},
          abi: Abi.linuxX64,
          run: (command, _) async =>
              ProcessResult(0, command == 'dpkg-query' ? 1 : 0, '', ''),
        );
        expect(await rpm.detect(), InstallKind.linuxRpm);
      },
    );
  });

  group('arming', () {
    VerifiedPayload payloadIn(Directory root) {
      final attempt = Directory(p.join(root.path, 'updates', 'v1.17.0-a'))
        ..createSync(recursive: true);
      final file = File(p.join(attempt.path, 'app.zip'))
        ..writeAsBytesSync(releaseBytes);
      return VerifiedPayload(file.path, '${sha256.convert(releaseBytes)}');
    }

    test('a helper that reports itself running is armed, and cancelling '
        'waits for it to stop', () async {
      final installer = portableInstaller(root);
      final payload = payloadIn(root);
      final started = await installer.schedule(
        payload,
        InstallKind.linuxPortable,
      );
      final armed = (started as HelperArmed).armed;
      expect(File(armed).existsSync(), isTrue);
      expect(
        File(p.join(payload.folder, 'install.sh')).readAsStringSync(),
        '# helper',
      );
      expect(await installer.cancel(armed), isTrue);
      expect(File(armed).existsSync(), isFalse);
    });

    test('the helper reopens the app only when asked, and an earlier '
        "run's request does not carry over", () async {
      final installer = portableInstaller(root);
      final payload = payloadIn(root);
      final reopen = File(p.join(payload.folder, reopenName));
      var started = await installer.schedule(
        payload,
        InstallKind.linuxPortable,
      );
      var armed = (started as HelperArmed).armed;
      expect(reopen.existsSync(), isFalse);
      expect(await installer.setReopen(armed, reopen: true), isTrue);
      expect(reopen.existsSync(), isTrue);
      expect(await installer.setReopen(armed, reopen: false), isTrue);
      expect(reopen.existsSync(), isFalse);

      // Left by a helper that was killed before it could tidy up.
      expect(await installer.setReopen(armed, reopen: true), isTrue);
      expect(await installer.cancel(armed), isTrue);
      started = await installer.schedule(payload, InstallKind.linuxPortable);
      armed = (started as HelperArmed).armed;
      expect(reopen.existsSync(), isFalse);
      expect(await installer.cancel(armed), isTrue);
    });

    test('a helper that never starts leaves nothing armed', () async {
      final installer = portableInstaller(
        root,
        helper: StandInHelper()..starts = false,
      );
      final payload = payloadIn(root);
      final started = await installer.schedule(
        payload,
        InstallKind.linuxPortable,
      );
      expect(started, isA<HelperNotStarted>());
      expect(File(p.join(payload.folder, armedName)).existsSync(), isFalse);
    });

    test('a ready file left by a killed helper is not taken for a running '
        'one', () async {
      final helper = StandInHelper()..starts = false;
      final installer = portableInstaller(root, helper: helper);
      final payload = payloadIn(root);
      final leftover = File(p.join(payload.folder, helperReadyName))
        ..writeAsStringSync('ready');
      expect(
        await installer.schedule(payload, InstallKind.linuxPortable),
        isA<HelperNotStarted>(),
      );
      expect(leftover.existsSync(), isFalse);

      leftover.writeAsStringSync('ready');
      final armed = p.join(payload.folder, armedName);
      expect(
        await installer.cancel(armed),
        isTrue,
        reason: 'no helper holds the lock, so none is running',
      );
      expect(leftover.existsSync(), isFalse);
    });

    test('a folder whose helper still runs is not armed again', () async {
      final helper = StandInHelper()..running = true;
      final installer = portableInstaller(root, helper: helper);
      final payload = payloadIn(root);
      final ready = File(p.join(payload.folder, helperReadyName))
        ..writeAsStringSync('ready');
      final started = await installer.schedule(
        payload,
        InstallKind.linuxPortable,
      );
      expect(started, isNot(isA<HelperArmed>()));
      expect(helper.launches, 0);
      expect(ready.existsSync(), isTrue, reason: 'still that helper\'s');
    });

    test(
      'the Windows request is written as UTF-8 JSON beside the payload',
      () async {
        final payload = payloadIn(root);
        List<String>? started;
        final installer = UpdateInstaller(
          readHelper: (_) async => '# ps1',
          executable: r'C:\Chess Auto Prep\chess_auto_prep.exe',
          environment: const {},
          abi: Abi.windowsX64,
          appPid: 9,
          startDetached: (_, arguments) async {
            started = arguments;
            File(
              p.join(payload.folder, helperReadyName),
            ).writeAsStringSync('ready');
          },
          readyPoll: const Duration(milliseconds: 5),
        );
        await installer.schedule(payload, InstallKind.windowsSetup);
        final request =
            jsonDecode(
                  File(
                    p.join(payload.folder, 'request.json'),
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        expect(request['processId'], 9);
        expect(request['payload'], payload.path);
        expect(
          request['executable'],
          r'C:\Chess Auto Prep\chess_auto_prep.exe',
        );
        expect(started, contains(p.join(payload.folder, 'install.ps1')));
      },
    );
  });

  test('the real Linux helper holds the install lock: a second one is not '
      'started over it, and cancelling stops it', () async {
    final app = Directory(p.join(root.path, 'app'))..createSync();
    File(
      p.join(app.path, UpdateInstaller.portableMarker),
    ).writeAsStringSync('1\n');
    final attempt = Directory(p.join(root.path, 'updates', 'v1.17.0-a'))
      ..createSync(recursive: true);
    final zip = File(p.join(attempt.path, 'app.zip'))
      ..writeAsBytesSync(releaseBytes);
    final payload = VerifiedPayload(
      zip.path,
      '${sha256.convert(releaseBytes)}',
    );
    final fakeApp = await Process.start('sleep', ['30']);
    addTearDown(fakeApp.kill);
    final installer = UpdateInstaller(
      readHelper: (asset) => File(asset).readAsString(),
      executable: p.join(app.path, 'chess_auto_prep'),
      environment: const {},
      abi: Abi.linuxX64,
      appPid: fakeApp.pid,
    );
    final updates = p.join(root.path, 'updates');
    expect(await installer.helperRunning(updates), isFalse);
    final armed =
        (await installer.schedule(payload, InstallKind.linuxPortable)
                as HelperArmed)
            .armed;
    expect(await installer.helperRunning(updates), isTrue);
    expect(
      await installer.schedule(payload, InstallKind.linuxPortable),
      isA<HelperBusy>(),
    );
    expect(File(armed).existsSync(), isTrue, reason: 'still armed');
    expect(File(p.join(attempt.path, helperReadyName)).existsSync(), isTrue);
    expect(await installer.cancel(armed), isTrue);
    expect(await installer.helperRunning(updates), isFalse);
    expect(File(p.join(updates, 'last-error.txt')).existsSync(), isFalse);
  }, skip: !Platform.isLinux || !_hasTools(['flock']));

  test('the real Linux helper starts while the app briefly probes its '
      'lock', () async {
    final app = Directory(p.join(root.path, 'app'))..createSync();
    File(
      p.join(app.path, UpdateInstaller.portableMarker),
    ).writeAsStringSync('1\n');
    final attempt = Directory(p.join(root.path, 'updates', 'v1.17.0-a'))
      ..createSync(recursive: true);
    final zip = File(p.join(attempt.path, 'app.zip'))
      ..writeAsBytesSync(releaseBytes);
    final payload = VerifiedPayload(
      zip.path,
      '${sha256.convert(releaseBytes)}',
    );
    final updates = p.join(root.path, 'updates');
    final lock = p.join(updates, 'install.lock');
    final fakeApp = await Process.start('sleep', ['30']);
    addTearDown(fakeApp.kill);
    Process? probe;
    final installer = UpdateInstaller(
      readHelper: (asset) => File(asset).readAsString(),
      executable: p.join(app.path, 'chess_auto_prep'),
      environment: const {},
      abi: Abi.linuxX64,
      appPid: fakeApp.pid,
      // Another probe of the lock is under way as the helper starts.
      startDetached: (executable, arguments) async {
        probe = await Process.start('flock', [lock, 'sleep', '0.5']);
        for (var i = 0; i < 100; i++) {
          final free = await Process.run('flock', ['-n', lock, 'true']);
          if (free.exitCode != 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Process.start(
          executable,
          arguments,
          mode: ProcessStartMode.detached,
        );
      },
    );
    final started = await installer.schedule(
      payload,
      InstallKind.linuxPortable,
    );
    await probe?.exitCode;
    expect(started, isA<HelperArmed>());
    expect(await installer.helperRunning(updates), isTrue);
    expect(await installer.cancel((started as HelperArmed).armed), isTrue);
    expect(File(p.join(updates, 'last-error.txt')).existsSync(), isFalse);
  }, skip: !Platform.isLinux || !_hasTools(['flock']));

  test('a command that does not answer in time is killed', () async {
    expect((await runBriefly('sh', ['-c', 'printf ok']))!.stdout, 'ok');
    expect(await runBriefly('no-such-command-for-updates', []), isNull);
    final pidFile = File(p.join(root.path, 'pid'));
    final answer = await runBriefly('sh', [
      '-c',
      r'echo $$ > "$1"; exec sleep 30',
      'sh',
      pidFile.path,
    ], timeout: const Duration(milliseconds: 300));
    expect(answer, isNull);
    final stat = File('/proc/${pidFile.readAsStringSync().trim()}/stat');
    bool alive() {
      try {
        // The state after the command name; a zombie is already dead.
        final state = stat.readAsStringSync().split(') ').last.split(' ')[0];
        return state != 'Z';
      } on FileSystemException {
        return false;
      }
    }

    for (var i = 0; i < 100 && alive(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(alive(), isFalse);
  }, skip: !Platform.isLinux);

  test('the real Linux helper swaps a portable v2 bundle after the app '
      'exits and restarts it', () async {
    final app = Directory(p.join(root.path, "Chess app 'quoted'"))
      ..createSync();
    File(
      p.join(app.path, UpdateInstaller.portableMarker),
    ).writeAsStringSync('1\n');
    File(p.join(app.path, 'chess_auto_prep')).writeAsStringSync('old');
    File(p.join(app.path, 'personal.pgn')).writeAsStringSync('mine');
    final bundle = Directory(p.join(root.path, 'bundle'))..createSync();
    File(p.join(bundle.path, 'chess_auto_prep')).writeAsStringSync(
      '#!/bin/sh\nprintf restarted > "\$(dirname "\$0")/restarted"\n',
    );
    Directory(p.join(bundle.path, 'lib')).createSync();
    File(p.join(bundle.path, 'lib', 'libapp.so')).writeAsStringSync('lib');
    Directory(p.join(bundle.path, 'data')).createSync();
    File(p.join(bundle.path, 'data', 'icudtl.dat')).writeAsStringSync('icu');
    File(
      p.join(bundle.path, UpdateInstaller.portableMarker),
    ).writeAsStringSync('1\n');
    await Process.run('chmod', ['+x', p.join(bundle.path, 'chess_auto_prep')]);
    final attempt = Directory(p.join(root.path, 'updates', 'v1.17.0-a'))
      ..createSync(recursive: true);
    final zip = p.join(attempt.path, 'chess-auto-prep-v1.17.0-linux.zip');
    final zipped = await Process.run('zip', [
      '-qr',
      zip,
      '.',
    ], workingDirectory: bundle.path);
    expect(zipped.exitCode, 0, reason: '${zipped.stderr}');
    final fakeApp = await Process.start('sleep', ['30']);
    addTearDown(fakeApp.kill);
    final installer = UpdateInstaller(
      readHelper: (asset) => File(asset).readAsString(),
      executable: p.join(app.path, 'chess_auto_prep'),
      environment: const {},
      abi: Abi.linuxX64,
      appPid: fakeApp.pid,
    );
    expect(await installer.detect(), InstallKind.linuxPortable);
    final digest = '${sha256.convert(File(zip).readAsBytesSync())}';
    final started = await installer.schedule(
      VerifiedPayload(zip, digest),
      InstallKind.linuxPortable,
    );
    expect(started, isA<HelperArmed>());
    expect(
      await installer.setReopen((started as HelperArmed).armed, reopen: true),
      isTrue,
    );
    expect(File(p.join(app.path, 'restarted')).existsSync(), isFalse);
    fakeApp.kill();
    final restarted = File(p.join(app.path, 'restarted'));
    for (var i = 0; i < 200 && !restarted.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(restarted.existsSync(), isTrue);
    expect(File(p.join(app.path, 'personal.pgn')).readAsStringSync(), 'mine');
    expect(
      root.listSync().where((e) => e.path.contains('.previous-')),
      hasLength(1),
    );
    expect(
      File(p.join(root.path, 'updates', 'last-error.txt')).existsSync(),
      isFalse,
    );
  }, skip: !Platform.isLinux || !_hasTools(['zip', 'unzip', 'flock']));
}

bool _hasTools(List<String> tools) => tools.every(
  (tool) => Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0,
);
