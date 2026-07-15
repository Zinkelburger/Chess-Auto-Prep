import 'package:chess_auto_prep/utils/keyboard_shortcut_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTextInputFocused', () {
    testWidgets('returns false when no focus', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Hello'))),
      );
      expect(isTextInputFocused(), isFalse);
    });

    testWidgets('returns true when TextField has focus', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
      );
      await tester.pump();
      expect(isTextInputFocused(), isTrue);
    });
  });
}
