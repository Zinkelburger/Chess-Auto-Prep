/// Read-only access to the desktop collection library and recent-file paths.
abstract interface class PgnLibraryRepository {
  Future<bool> exists(String path);
  Future<String> collectionsDirectory();
  String parentDirectory(String path);
}
