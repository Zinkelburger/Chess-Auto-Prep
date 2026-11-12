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
  return uri == null ? null : exportedPlace(uri);
}

/// Where a saved export went, for the message that says so: a file's path,
/// or the address a platform gave it when it is not a file.
String exportedPlace(Uri uri) =>
    uri.scheme == 'file' ? uri.toFilePath() : '$uri';
