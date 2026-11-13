import 'package:chess_auto_prep/workspace/document/save_copy.dart';
import 'package:chess_auto_prep/workspace/document/session_results.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a copy says it is being edited only when the session moved to it', () {
    expect(copySaid(const CopySaved('Main copy')), 'Saved a copy as Main copy');
    expect(
      copySaid(const CopySaved('Main copy', nowEditing: true)),
      'Saved a copy as Main copy. Now editing the copy.',
    );
  });
}
