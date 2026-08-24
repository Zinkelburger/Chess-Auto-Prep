/// Platform detection for tactics analysis (native only).
///
/// Only imported on native platforms (desktop) via conditional import.
/// Parallel analysis itself is handled by [StockfishPool].
library;

import 'dart:io';

/// Whether parallel multi-core analysis is available on this platform.
bool get isParallelAnalysisAvailable =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Number of logical CPU cores reported by the host OS.
int get availableProcessors => Platform.numberOfProcessors;
