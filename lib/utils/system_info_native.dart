/// Native (desktop/mobile) system info — detects RAM, CPU cores, and live load.
library;

import 'dart:io';

/// Returns total system RAM in megabytes.
///
/// Detection strategy:
/// - **Linux**: reads `/proc/meminfo` for `MemTotal`
/// - **macOS**: runs `sysctl -n hw.memsize`
/// - **Windows**: runs `wmic computersystem get TotalPhysicalMemory`
/// - **Fallback**: 4096 MB
int getSystemRamMb() {
  try {
    if (Platform.isLinux) {
      return _linuxRamMb();
    } else if (Platform.isMacOS) {
      return _macosRamMb();
    } else if (Platform.isWindows) {
      return _windowsRamMb();
    }
  } catch (_) {
    // Fallback on any error
  }
  return 4096;
}

/// Returns the number of logical CPU cores.
int getLogicalCores() {
  try {
    return Platform.numberOfProcessors;
  } catch (_) {
    return 2;
  }
}

// ── Linux ────────────────────────────────────────────────────────────────

int _linuxRamMb() {
  final contents = File('/proc/meminfo').readAsStringSync();
  // MemTotal:       16384000 kB
  final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(contents);
  if (match != null) {
    final kb = int.parse(match.group(1)!);
    return kb ~/ 1024;
  }
  return 4096;
}

// ── macOS ────────────────────────────────────────────────────────────────

int _macosRamMb() {
  final result = Process.runSync('sysctl', ['-n', 'hw.memsize']);
  if (result.exitCode == 0) {
    final bytes = int.tryParse((result.stdout as String).trim());
    if (bytes != null) {
      return bytes ~/ (1024 * 1024);
    }
  }
  return 4096;
}

// ── Windows ──────────────────────────────────────────────────────────────

int _windowsRamMb() {
  final result = Process.runSync(
    'wmic',
    ['computersystem', 'get', 'TotalPhysicalMemory'],
  );
  if (result.exitCode == 0) {
    final output = (result.stdout as String).trim();
    // Output is:  TotalPhysicalMemory\n17179869184
    final lines = output.split('\n');
    for (final line in lines) {
      final bytes = int.tryParse(line.trim());
      if (bytes != null && bytes > 0) {
        return bytes ~/ (1024 * 1024);
      }
    }
  }
  return 4096;
}

// ════════════════════════════════════════════════════════════════════════════
// Live system load detection
// ════════════════════════════════════════════════════════════════════════════

/// Snapshot of current system CPU and RAM usage.
class SystemLoad {
  /// Approximate CPU usage as a percentage (0.0 – 100.0).
  /// Derived from the 1-minute load average / logical cores.
  final double cpuPercent;

  /// RAM usage as a percentage (0.0 – 100.0).
  /// (totalRam - availableRam) / totalRam.
  final double ramPercent;

  /// Total physical RAM in megabytes.
  final int totalRamMb;

  /// Currently free / reclaimable RAM in megabytes.
  final int freeRamMb;

  /// Number of logical CPU cores (hyper-threads).
  final int logicalCores;

  SystemLoad({
    required this.cpuPercent,
    required this.ramPercent,
    required this.totalRamMb,
    required this.freeRamMb,
    required this.logicalCores,
  });

  /// The higher of CPU or RAM usage.
  double get maxPercent => cpuPercent > ramPercent ? cpuPercent : ramPercent;

  /// Estimated number of idle cores.
  ///
  /// Derived from `logicalCores × (1 − cpuPercent / 100)`.
  /// On Linux/macOS this maps directly to `cores − loadAvg`; on Windows
  /// it approximates from the aggregate CPU percentage.
  double get freeCores =>
      (logicalCores * (1.0 - cpuPercent / 100.0)).clamp(0.0, logicalCores.toDouble());

  /// Available RAM headroom in MB under a target ceiling.
  ///
  /// Formula: `ceiling * totalRam − usedRam`, clamped to [0, totalRam].
  /// A return of 0 means no headroom at all.
  int headroomMb(double ceilingFraction) {
    final usedMb = totalRamMb - freeRamMb;
    return ((ceilingFraction * totalRamMb).round() - usedMb)
        .clamp(0, totalRamMb);
  }
}

/// Returns a live snapshot of system CPU and RAM usage, or null on failure.
SystemLoad? getSystemLoad() {
  try {
    if (Platform.isLinux) {
      return _linuxLoad();
    } else if (Platform.isMacOS) {
      return _macosLoad();
    } else if (Platform.isWindows) {
      return _windowsLoad();
    }
  } catch (_) {}
  return null;
}

// ── Linux live load ───────────────────────────────────────────────────────

SystemLoad? _linuxLoad() {
  // CPU: 1-minute load average from /proc/loadavg
  // Format: "1.23 0.89 0.45 2/345 12345"
  final loadAvgStr = File('/proc/loadavg').readAsStringSync();
  final loadAvg = double.tryParse(loadAvgStr.split(' ').first);
  if (loadAvg == null) return null;
  final cores = Platform.numberOfProcessors;
  final cpuPercent = (loadAvg / cores * 100).clamp(0.0, 100.0);

  // RAM: MemTotal and MemAvailable from /proc/meminfo
  final meminfo = File('/proc/meminfo').readAsStringSync();
  final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(meminfo);
  final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(meminfo);
  if (totalMatch == null || availMatch == null) return null;
  final totalKb = int.parse(totalMatch.group(1)!);
  final availKb = int.parse(availMatch.group(1)!);
  final ramPercent = ((totalKb - availKb) / totalKb * 100).clamp(0.0, 100.0);

  return SystemLoad(
    cpuPercent: cpuPercent,
    ramPercent: ramPercent,
    totalRamMb: totalKb ~/ 1024,
    freeRamMb: availKb ~/ 1024,
    logicalCores: cores,
  );
}

// ── macOS live load ───────────────────────────────────────────────────────

SystemLoad? _macosLoad() {
  // CPU: 1-minute load average from sysctl
  // Output: "{ 1.23 0.89 0.45 }"
  final loadResult = Process.runSync('sysctl', ['-n', 'vm.loadavg']);
  if (loadResult.exitCode != 0) return null;
  final loadStr = (loadResult.stdout as String).trim();
  final loadMatch = RegExp(r'[\d.]+').firstMatch(loadStr);
  if (loadMatch == null) return null;
  final loadAvg = double.tryParse(loadMatch.group(0)!);
  if (loadAvg == null) return null;
  final cores = Platform.numberOfProcessors;
  final cpuPercent = (loadAvg / cores * 100).clamp(0.0, 100.0);

  // RAM: Parse vm_stat for page counts
  final vmResult = Process.runSync('vm_stat', []);
  if (vmResult.exitCode != 0) return null;
  final vmOutput = vmResult.stdout as String;

  // Page size from header: "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
  final pageSizeMatch = RegExp(r'page size of (\d+)').firstMatch(vmOutput);
  final pageSize = pageSizeMatch != null
      ? int.parse(pageSizeMatch.group(1)!)
      : 16384;

  int? parsePages(String label) {
    final match = RegExp('$label:\\s+(\\d+)').firstMatch(vmOutput);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  final free = parsePages('Pages free') ?? 0;
  final active = parsePages('Pages active') ?? 0;
  final inactive = parsePages('Pages inactive') ?? 0;
  final speculative = parsePages('Pages speculative') ?? 0;
  final wired = parsePages('Pages wired down') ?? 0;

  final totalPages = free + active + inactive + speculative + wired;
  if (totalPages == 0) return null;
  final usedPages = active + wired; // conservatively, active + wired are "in use"
  final ramPercent = (usedPages / totalPages * 100).clamp(0.0, 100.0);

  final pageSizeMb = pageSize / (1024 * 1024);
  final totalRamMb = (totalPages * pageSizeMb).round();
  // free + inactive + speculative are reclaimable
  final freeRamMb = ((free + inactive + speculative) * pageSizeMb).round();

  return SystemLoad(
    cpuPercent: cpuPercent,
    ramPercent: ramPercent,
    totalRamMb: totalRamMb,
    freeRamMb: freeRamMb,
    logicalCores: cores,
  );
}

// ── Windows live load ─────────────────────────────────────────────────────

SystemLoad? _windowsLoad() {
  // CPU: wmic cpu get LoadPercentage
  // Output: "LoadPercentage\n42"
  final cpuResult = Process.runSync(
    'wmic', ['cpu', 'get', 'LoadPercentage'],
  );
  double cpuPercent = 0;
  if (cpuResult.exitCode == 0) {
    for (final line in (cpuResult.stdout as String).split('\n')) {
      final val = int.tryParse(line.trim());
      if (val != null) {
        cpuPercent = val.toDouble().clamp(0.0, 100.0);
        break;
      }
    }
  }

  // RAM: wmic OS get FreePhysicalMemory (returns KB)
  final ramResult = Process.runSync(
    'wmic', ['OS', 'get', 'FreePhysicalMemory,TotalVisibleMemorySize'],
  );
  double ramPercent = 0;
  int totalRamMb = getSystemRamMb();
  int freeRamMb = totalRamMb;
  if (ramResult.exitCode == 0) {
    // Output: "FreePhysicalMemory  TotalVisibleMemorySize\n8192000  16384000"
    final lines = (ramResult.stdout as String).trim().split('\n');
    if (lines.length >= 2) {
      final values = lines.last.trim().split(RegExp(r'\s+'));
      if (values.length >= 2) {
        final freeKb = int.tryParse(values[0]);
        final totalKb = int.tryParse(values[1]);
        if (freeKb != null && totalKb != null && totalKb > 0) {
          ramPercent = ((totalKb - freeKb) / totalKb * 100).clamp(0.0, 100.0);
          totalRamMb = totalKb ~/ 1024;
          freeRamMb = freeKb ~/ 1024;
        }
      }
    }
  }

  return SystemLoad(
    cpuPercent: cpuPercent,
    ramPercent: ramPercent,
    totalRamMb: totalRamMb,
    freeRamMb: freeRamMb,
    logicalCores: Platform.numberOfProcessors,
  );
}
