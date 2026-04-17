/// Native (desktop/mobile) system info — detects CPU cores.
library;

import 'dart:io';

/// Returns the number of logical CPU cores.
int getLogicalCores() {
  try {
    return Platform.numberOfProcessors;
  } catch (_) {
    return 2;
  }
}
