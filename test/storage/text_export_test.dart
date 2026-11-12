import 'package:chess_auto_prep/storage/text_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a saved export names its file by path, anything else by address', () {
    expect(
      exportedPlace(Uri.file('/home/u/Documents/Prep sheet.md')),
      '/home/u/Documents/Prep sheet.md',
    );
    expect(
      exportedPlace(Uri.parse('content://downloads/document/12')),
      'content://downloads/document/12',
    );
  });
}
