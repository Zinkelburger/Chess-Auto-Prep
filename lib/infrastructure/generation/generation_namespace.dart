import 'dart:io';
import 'package:path/path.dart' as p;

/// Only owned directories under the source's existing parent are writable.
Future<void> prepareGenerationDirectory(
  String directory, {
  bool exclusive = true,
}) async {
  final chapter = p.dirname(directory);
  final namespace = p.dirname(chapter);
  if (!await Directory(p.dirname(namespace)).exists()) {
    throw FileSystemException('Source directory is absent', directory);
  }
  for (final path in [namespace, chapter, directory]) {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(path).create();
    } else if (type != FileSystemEntityType.directory ||
        (exclusive && path == directory)) {
      throw FileSystemException('Generation namespace collision', path);
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('Generation directory changed', path);
    }
  }
}
