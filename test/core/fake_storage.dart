/// In-memory [StorageService] for controller tests that only read and write
/// files by path. Every other member throws, so a test cannot pass on a
/// storage call it never meant to make.
library;

import 'package:chess_auto_prep/services/storage/storage_service.dart';

class MemoryStorage implements StorageService {
  final Map<String, String> files = {};

  /// Every write throws when set — the "disk full" case.
  bool failWrites = false;

  /// Awaited before each existence check; lets a test hold a read open.
  Future<void> Function(String path)? beforeExists;

  @override
  Future<bool> fileExists(String path) async {
    await beforeExists?.call(path);
    return files.containsKey(path);
  }

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrites) throw StateError('disk full');
    if (createOnly && files.containsKey(path)) {
      throw StateError('file exists');
    }
    files[path] = content;
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
