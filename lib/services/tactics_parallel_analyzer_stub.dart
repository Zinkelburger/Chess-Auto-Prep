/// Stub for web / non-IO platforms where dart:io is unavailable.
library;

/// Whether parallel multi-core analysis is available on this platform.
bool get isParallelAnalysisAvailable => false;

/// Not available on this platform — returns 1 as a safe fallback.
int get availableProcessors => 1;
