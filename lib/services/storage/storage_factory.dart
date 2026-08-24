import 'package:flutter/foundation.dart';

import 'storage_service.dart';
import 'io_storage_service.dart';

class StorageFactory {
  static StorageService? _instance;

  static StorageService get instance {
    _instance ??= getStorageService();
    return _instance!;
  }

  /// Test-only: stand a stub in for the real file-backed storage. Pass null to
  /// restore it — every test that sets this must put it back.
  @visibleForTesting
  static set instanceForTest(StorageService? service) => _instance = service;
}
