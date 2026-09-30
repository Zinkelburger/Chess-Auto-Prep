// A TWIC import with no room left, on a real full filesystem: a tiny tmpfs
// inside an unprivileged mount namespace, as `disk_full_test.dart` does for
// documents. Machines that cannot make one skip with the reason.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _harness = 'test/storage/harness/master_games_import.dart';

String? _cannotMount() {
  if (!Platform.isLinux) return 'Linux only';
  final probe = Process.runSync('unshare', [
    '-Urm',
    '--propagation',
    'private',
    'sh',
    '-c',
    'mount -t tmpfs -o size=64k tmpfs /tmp && echo mounted',
  ]);
  if (probe.exitCode != 0 || !'${probe.stdout}'.contains('mounted')) {
    return 'cannot mount a tmpfs in a user namespace: ${probe.stderr}';
  }
  return null;
}

void main() {
  test(
    'a full disk fails the issue as a full disk, keeps earlier issues and '
    'imports it once there is room',
    () async {
      final mount = await Directory.systemTemp.createTemp('v2-twic-full-');
      addTearDown(() => mount.delete(recursive: true));
      final run = await Process.run('unshare', [
        '-Urm',
        '--propagation',
        'private',
        'sh',
        '-c',
        'mount -t tmpfs -o size=4m tmpfs "\$1" && exec "\$2" run $_harness full "\$1"',
        'sh',
        mount.path,
        'dart',
      ], workingDirectory: Directory.current.path);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final report =
          jsonDecode(
                const LineSplitter()
                    .convert('${run.stdout}')
                    .lastWhere((line) => line.startsWith('{')),
              )
              as Map<String, Object?>;
      expect(report['first'], 20);
      expect(report['filled'], greaterThan(10));
      expect(report['full'], 'The disk is full.', reason: '${report['error']}');
      expect(report['afterwards'], [1]);
      expect(report['retried'], 3000);
      expect(report['finally'], [1, 2]);
      expect(report['leftovers'], isEmpty, reason: 'no journal left behind');
    },
    skip: _cannotMount(),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
