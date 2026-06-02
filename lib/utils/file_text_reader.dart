import 'dart:convert';
import 'dart:io';

Future<String> readTextFile(File file) async {
  return decodeTextBytes(await file.readAsBytes());
}

String decodeTextBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}
