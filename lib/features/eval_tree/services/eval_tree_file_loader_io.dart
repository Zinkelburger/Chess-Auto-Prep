import 'dart:io' as io;

const bool isEvalTreeFileAccessSupported = true;
const String evalTreeFileAccessUnsupportedReason = '';

Future<bool> evalTreeFileExists(String path) async {
  return io.File(path).exists();
}

Future<String> readEvalTreeFile(String path) async {
  return io.File(path).readAsString();
}
