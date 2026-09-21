import 'package:file_picker/file_picker.dart';

import '../diagnostics/log.dart';

/// The operating system's file dialog, asked for one PGN file.
///
/// A real boundary — the dialog is the desktop's, not this app's — so it is
/// an interface: [NativePgnFilePicker] in the app, a scripted one in tests.
abstract interface class PgnFilePicker {
  /// The path the user chose, or null when they closed the dialog without
  /// choosing. [startIn] is the folder the dialog opens on, when there is a
  /// better one than the desktop's default.
  Future<String?> pickPgn({String? startIn});
}

final class NativePgnFilePicker implements PgnFilePicker {
  const NativePgnFilePicker();

  @override
  Future<String?> pickPgn({String? startIn}) async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Open PGN file',
        initialDirectory: startIn,
        type: FileType.custom,
        allowedExtensions: const ['pgn', 'txt'],
      );
      return file?.path;
    } on Object catch (error) {
      // A dialog that will not open is the desktop's failure; the user saw
      // nothing happen, and this says why.
      log.w('open the file dialog', error);
      return null;
    }
  }
}
