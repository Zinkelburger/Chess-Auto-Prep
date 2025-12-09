import 'storage_service.dart';
import 'io_storage_service.dart' if (dart.library.html) 'web_storage_service.dart';

class StorageFactory {
  static StorageService? _instance;

  static StorageService get instance {
    _instance ??= getStorageService();
    return _instance!;
  }
}
