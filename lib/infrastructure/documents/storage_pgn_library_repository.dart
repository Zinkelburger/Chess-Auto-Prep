import '../../features/documents/repositories/pgn_library_repository.dart';
import '../../services/storage/storage_service.dart';

class StoragePgnLibraryRepository implements PgnLibraryRepository {
  StoragePgnLibraryRepository(this.storage, {required this.directory});
  final StorageService storage;
  final Future<String> Function() directory;

  @override
  Future<bool> exists(String path) => storage.fileExists(path);
  @override
  Future<String> collectionsDirectory() => directory();
  @override
  String parentDirectory(String path) => storage.parentPath(path);
}
