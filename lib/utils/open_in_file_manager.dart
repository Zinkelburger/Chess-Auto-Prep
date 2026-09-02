/// Show a file or folder in the desktop's own file manager.
library;

import 'dart:io';

/// Opens [path] in the system file manager.
///
/// Returns false when no handler could be launched — callers fall back to
/// showing the path as copyable text rather than reporting a failure the user
/// can do nothing about.
Future<bool> openInFileManager(String path) async {
  final entity = FileSystemEntity.typeSync(path);
  if (entity == FileSystemEntityType.notFound) return false;

  final (
    String command,
    List<String> args,
  ) = switch (Platform.operatingSystem) {
    'linux' => ('xdg-open', [path]),
    'macos' => ('open', [path]),
    'windows' => ('explorer', [path]),
    _ => ('', <String>[]),
  };
  if (command.isEmpty) return false;

  try {
    final result = await Process.run(command, args);
    // Windows Explorer returns 1 even when it opened the window.
    return result.exitCode == 0 || Platform.isWindows;
  } on ProcessException {
    return false;
  }
}
