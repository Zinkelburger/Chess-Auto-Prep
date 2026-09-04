/// License entries for native assets bundled outside Flutter's package graph.
///
/// Dart package licenses are collected automatically. Hivemind is a separate
/// executable and neural-network bundle, so its MIT notice must be registered
/// explicitly to travel with the desktop app and appear in the license page.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString(
      'assets/licenses/HIVEMIND_LICENSE.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['Hivemind bughouse engine'], text);
  });
}
