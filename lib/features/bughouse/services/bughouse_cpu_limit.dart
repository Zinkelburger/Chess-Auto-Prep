import 'dart:io';

/// Limits every thread of the analysis child, within the parent's CPU set.
class BughouseCpuLimit {
  static bool get supported => Platform.isLinux;
  static List<int> get allowed {
    if (!supported) return List.generate(Platform.numberOfProcessors, (i) => i);
    final status = File('/proc/self/status').readAsStringSync();
    final list = RegExp(
      r'^Cpus_allowed_list:\s*(.+)$',
      multiLine: true,
    ).firstMatch(status)!.group(1)!;
    return parseCpuList(list);
  }

  static List<int> parseCpuList(String list) => [
    for (final part in list.trim().split(','))
      for (
        var i = int.parse(part.split('-').first);
        i <= int.parse(part.split('-').last);
        i++
      )
        i,
  ];

  static int get available => allowed.length;

  static Future<void> apply(int pid, int cores) async {
    if (!supported) return;
    final cpus = allowed;
    final selected = cpus.take(cores.clamp(1, cpus.length)).join(',');
    final result = await Process.run('taskset', [
      '--all-tasks',
      '--pid',
      '--cpu-list',
      selected,
      '$pid',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not set analysis CPU cores: ${result.stderr}');
    }
  }
}
