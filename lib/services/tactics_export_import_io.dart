import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chess_auto_prep/utils/log.dart';

/// Native (mobile/desktop) implementation for exporting a puzzle-set file
/// (CSV or PGN — the extension comes from [filename]).
Future<void> exportContent(
    String content, String filename, int positionCount) async {
  // On mobile, use share sheet
  if (Platform.isAndroid || Platform.isIOS) {
    // Create a temporary file for sharing
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(p.join(tempDir.path, filename));
    await tempFile.writeAsString(content);

    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(tempFile.path)],
        subject: 'Chess Tactics - $positionCount positions',
        text: 'Export of $positionCount chess tactics positions',
      ),
    );

    if (result.status == ShareResultStatus.success) {
      log.i('Tactics exported successfully');
    }

    // Clean up temp file
    try {
      await tempFile.delete();
    } catch (_) {/* temp-file cleanup — ignore */}
  } else {
    // On desktop, let user choose save location
    final extension = p.extension(filename).replaceFirst('.', '');
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Export Tactics',
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: [if (extension.isNotEmpty) extension else 'csv'],
      bytes: utf8.encode(content),
    );

    if (savePath != null) {
      log.i('Tactics exported to: $savePath');
    }
  }
}
