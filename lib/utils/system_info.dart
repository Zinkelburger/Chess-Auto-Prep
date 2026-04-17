/// Cross-platform system info (CPU cores).
///
/// Uses conditional imports: native detection on desktop/mobile,
/// conservative fallbacks on web.
library;

import 'system_info_stub.dart'
    if (dart.library.io) 'system_info_native.dart' as platform;

/// Number of logical CPU cores.
int getLogicalCores() => platform.getLogicalCores();
