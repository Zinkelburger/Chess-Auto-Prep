/// Cross-platform system info (RAM, CPU cores, live load).
///
/// Uses conditional imports: native detection on desktop/mobile,
/// conservative fallbacks on web.
library;

import 'system_info_stub.dart'
    if (dart.library.io) 'system_info_native.dart' as platform;

/// Re-export [SystemLoad] so consumers don't need the platform import.
typedef SystemLoad = platform.SystemLoad;

/// Total system RAM in megabytes.
int getSystemRamMb() => platform.getSystemRamMb();

/// Number of logical CPU cores.
int getLogicalCores() => platform.getLogicalCores();

/// Live snapshot of CPU and RAM usage, or null if unavailable (web).
SystemLoad? getSystemLoad() => platform.getSystemLoad();

/// Suggested default Stockfish hash budget (50% of system RAM).
int defaultHashMb() {
  final totalMb = getSystemRamMb();
  // 50% of system RAM, floor at 64 MB, no upper cap
  final half = totalMb ~/ 2;
  return half < 64 ? 64 : half;
}

/// Suggested default parallel worker count (half of logical cores, floor 1).
int defaultWorkerCount() {
  final cores = getLogicalCores();
  final half = cores ~/ 2;
  return half < 1 ? 1 : half;
}
