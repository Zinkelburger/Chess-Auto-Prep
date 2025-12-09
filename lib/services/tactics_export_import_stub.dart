/// Stub implementation - should never be called
/// Platform-specific implementations are in:
/// - tactics_export_import_io.dart (mobile/desktop)
/// - tactics_export_import_web.dart (web)

Future<void> exportCsvContent(String content, String filename, int positionCount) async {
  throw UnsupportedError('Platform not supported for export');
}

