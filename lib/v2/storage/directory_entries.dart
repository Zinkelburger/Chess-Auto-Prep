import 'dart:io';

import 'package:path/path.dart' as p;

/// Dart's Windows directory enumerator still reaches MAX_PATH on hosts that
/// have not opted into long paths (including flutter_tester). Use the extended
/// namespace for the OS call, then return the caller's spelling so document
/// references and backup keys do not acquire a second identity.
Stream<FileSystemEntity> directoryEntries(
  Directory folder, {
  bool recursive = false,
  bool followLinks = true,
}) async* {
  if (!Platform.isWindows) {
    yield* folder.list(recursive: recursive, followLinks: followLinks);
    return;
  }
  final path = p.normalize(p.absolute(folder.path));
  final extended = path.startsWith(r'\\?\')
      ? path
      : path.startsWith(r'\\')
      ? r'\\?\UNC\' + path.substring(2)
      : r'\\?\' + path;
  final native = Directory(extended);
  await for (final entry in native.list(
    recursive: recursive,
    followLinks: followLinks,
  )) {
    final original = p.join(
      folder.path,
      p.relative(entry.path, from: extended),
    );
    yield switch (entry) {
      Directory() => Directory(original),
      Link() => Link(original),
      _ => File(original),
    };
  }
}
