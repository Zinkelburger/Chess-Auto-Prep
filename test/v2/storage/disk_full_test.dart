// A save with no room left on the disk: the plan's disk-full test.
//
// A real ENOSPC needs a real full filesystem, so the store runs in a child
// process inside an unprivileged mount namespace (`unshare -Urm`) where the
// test folder is a tiny tmpfs. Machines that cannot make one — no user
// namespaces, no `unshare`, not Linux — skip with the reason.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _harness = 'test/v2/storage/harness/disk_full.dart';

/// Whether this machine can give a folder its own tiny filesystem.
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
  final skip = _cannotMount();

  test(
    'a save that runs out of room is a failure that leaves the document as '
    'it was, and lands once there is room',
    () async {
      final mount = await Directory.systemTemp.createTemp('v2-disk-full-');
      addTearDown(() => mount.delete(recursive: true));
      final run = await Process.run('unshare', [
        '-Urm',
        '--propagation',
        'private',
        'sh',
        '-c',
        'mount -t tmpfs -o size=256k tmpfs "\$1" && exec "\$2" run $_harness "\$1"',
        'sh',
        mount.path,
        'dart', // the SDK on PATH; under `flutter test` the VM is the runner
      ], workingDirectory: Directory.current.path);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final lines = const LineSplitter().convert('${run.stdout}');
      final report =
          jsonDecode(lines.lastWhere((line) => line.startsWith('{')))
              as Map<String, Object?>;

      expect(report['filled'], greaterThan(10), reason: 'the disk was small');
      final save = report['save'] as Map<String, Object?>;
      expect(save['result'], 'IoFailure');
      expect(save['detail'], contains('No space left'));
      expect(report['afterwards'], {'text': '[Event "Main"]\n\n1. d4 *\n'});
      expect(
        report['staged copies'],
        isEmpty,
        reason: 'the half-written copy was removed',
      );
      expect((report['retried'] as Map<String, Object?>)['result'], 'Saved');
      expect(report['finally'], {'text': 'big'});
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
