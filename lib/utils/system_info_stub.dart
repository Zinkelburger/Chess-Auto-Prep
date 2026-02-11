/// Stub for web — no system info available.
library;

int getSystemRamMb() => 4096; // Conservative web default
int getLogicalCores() => 2;   // Conservative web default

/// Stub — live load detection not available on web.
class SystemLoad {
  final double cpuPercent;
  final double ramPercent;
  final int totalRamMb;
  final int freeRamMb;
  final int logicalCores;

  SystemLoad({
    required this.cpuPercent,
    required this.ramPercent,
    this.totalRamMb = 4096,
    this.freeRamMb = 2048,
    this.logicalCores = 2,
  });

  double get maxPercent => cpuPercent > ramPercent ? cpuPercent : ramPercent;

  double get freeCores =>
      (logicalCores * (1.0 - cpuPercent / 100.0)).clamp(0.0, logicalCores.toDouble());

  int headroomMb(double ceilingFraction) {
    final usedMb = totalRamMb - freeRamMb;
    return ((ceilingFraction * totalRamMb).round() - usedMb)
        .clamp(0, totalRamMb);
  }
}

SystemLoad? getSystemLoad() => null;
