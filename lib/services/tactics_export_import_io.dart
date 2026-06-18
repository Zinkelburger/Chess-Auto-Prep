import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chess_auto_prep/utils/log.dart';

/// Native (mobile/desktop) implementation for exporting CSV
Future<void> exportCsvContent(
    String content, String filename, int positionCount) async {
  // On mobile, use share sheet
  if (Platform.isAndroid || Platform.isIOS) {
    // Create a temporary file for sharing
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(p.join(tempDir.path, filename));
    await tempFile.writeAsString(content);

    final result = await Share.shareXFiles(
      [XFile(tempFile.path)],
      subject: 'Chess Tactics - $positionCount positions',
      text: 'Export of $positionCount chess tactics positions',
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
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Export Tactics',
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (savePath != null) {
      await File(savePath).writeAsString(content);
      log.i('Tactics exported to: $savePath');
    }
  }
}
