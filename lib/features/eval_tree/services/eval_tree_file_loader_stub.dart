const bool isEvalTreeFileAccessSupported = false;
const String evalTreeFileAccessUnsupportedReason =
    'Saved eval tree files are not available on this platform.';

Future<bool> evalTreeFileExists(String path) async {
  return false;
}

Future<String> readEvalTreeFile(String path) async {
  throw UnsupportedError(evalTreeFileAccessUnsupportedReason);
}
