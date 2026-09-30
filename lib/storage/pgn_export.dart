import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'file_lock.dart';

sealed class PgnExportResult {
  const PgnExportResult();
}

final class PgnExported extends PgnExportResult {
  const PgnExported(this.path);
  final String path;
}

final class PgnExportCancelled extends PgnExportResult {
  const PgnExportCancelled();
}

final class PgnExportFailed extends PgnExportResult {
  const PgnExportFailed(this.message);
  final String message;
}

/// An explicit snapshot outside the document collection. The directory picker
/// never writes; exclusive native publication refuses even a late collision.
final class PgnExport {
  const PgnExport({this.pickDirectory = _pickDirectory});
  final Future<String?> Function() pickDirectory;
  Future<PgnExportResult> save(String name, String text) async {
    if (name.isEmpty ||
        p.basename(name) != name ||
        name.contains(RegExp(r'[\\/\x00-\x1f]')))
      return const PgnExportFailed('Use a file name without path separators.');
    try {
      final folder = await pickDirectory();
      if (folder == null) return const PgnExportCancelled();
      final path = p.join(folder, name);
      await withDirectoryLock(
        Directory(folder),
        () async => createFileExclusively(path, utf8.encode(text)),
      );
      return PgnExported(path);
    } on NativeNameCollision {
      return const PgnExportFailed(
        'That file already exists. Choose another name.',
      );
    } on Object catch (error) {
      log.w('export PGN', error);
      return PgnExportFailed('Could not export PGN: $error');
    }
  }
}

Future<String?> _pickDirectory() =>
    FilePicker.getDirectoryPath(dialogTitle: 'Export PGN to folder');
