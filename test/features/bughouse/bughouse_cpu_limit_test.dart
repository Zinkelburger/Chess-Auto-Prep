import 'dart:io';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_cpu_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CPU lists preserve discontiguous allowed ranges', () {
    expect(BughouseCpuLimit.parseCpuList('2-4,8,11-12'), [2, 3, 4, 8, 11, 12]);
  });
  test(
    'limits and then restores child CPU affinity within the parent set',
    () async {
      if (!Platform.isLinux) return;
      final process = await Process.start('sleep', ['30']);
      try {
        await BughouseCpuLimit.apply(process.pid, 1);
        String cpuList() =>
            RegExp(r'^Cpus_allowed_list:\s*(.+)$', multiLine: true)
                .firstMatch(
                  File('/proc/${process.pid}/status').readAsStringSync(),
                )!
                .group(1)!;
        expect(BughouseCpuLimit.parseCpuList(cpuList()), [
          BughouseCpuLimit.allowed.first,
        ]);
        await BughouseCpuLimit.apply(process.pid, BughouseCpuLimit.available);
        expect(
          BughouseCpuLimit.parseCpuList(cpuList()),
          BughouseCpuLimit.allowed,
        );
      } finally {
        process.kill();
        await process.exitCode;
      }
    },
  );
}
