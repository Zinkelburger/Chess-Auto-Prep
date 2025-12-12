import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Web implementation for exporting CSV - triggers browser download
Future<void> exportCsvContent(String content, String filename, int positionCount) async {
  // Create a blob from the CSV content
  final bytes = utf8.encode(content);
  final blob = html.Blob([bytes], 'text/csv');
  
  // Create a download URL
  final url = html.Url.createObjectUrlFromBlob(blob);
  
  // Create an anchor element and trigger download
  final anchor = html.AnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  
  html.document.body?.append(anchor);
  anchor.click();
  
  // Clean up
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  
  print('Tactics export triggered for download: $filename');
}



