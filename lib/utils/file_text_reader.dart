import 'dart:convert';
import 'dart:io';

class TextDecodeResult {
  final String text;
  final bool usedLatin1Fallback;

  const TextDecodeResult({
    required this.text,
    this.usedLatin1Fallback = false,
  });
}

Future<String> readTextFile(File file) async {
  return decodeTextBytes(await file.readAsBytes());
}

String readTextFileSync(File file) {
  return decodeTextBytes(file.readAsBytesSync());
}

String decodeTextBytes(List<int> bytes) {
  return decodeTextBytesDetailed(bytes).text;
}

TextDecodeResult decodeTextBytesDetailed(List<int> bytes) {
  try {
    return TextDecodeResult(text: utf8.decode(bytes));
  } on FormatException {
    return TextDecodeResult(
      text: latin1.decode(bytes),
      usedLatin1Fallback: true,
    );
  }
}
