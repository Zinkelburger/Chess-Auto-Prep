import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// User-selected text exports are separate from the app's source documents.
Future<String?> saveTextExport(String name, String text) async {
  final uri = await FilePicker.saveFile(
    fileName: name,
    bytes: Uint8List.fromList(utf8.encode(text)),
    mimeType: 'text/markdown',
    dialogTitle: 'Export prep sheet',
  );
  return uri == null
      ? null
      : uri.scheme == 'file'
      ? uri.toFilePath()
      : '$uri';
}
