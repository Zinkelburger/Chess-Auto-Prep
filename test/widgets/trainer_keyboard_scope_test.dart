import 'package:chess_auto_prep/widgets/trainer_keyboard_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrainerKeyboardScope', () {
    late FocusNode node;
    late List<LogicalKeyboardKey> seen;

    setUp(() {
      node = FocusNode(debugLabel: 'panel');
      seen = <LogicalKeyboardKey>[];
      addTearDown(node.dispose);
    });

    Widget build({Widget? child}) => MaterialApp(
      home: Scaffold(
        body: TrainerKeyboardScope(
          holdsFocus: true,
          focusNode: node,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) seen.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child:
              child ??
              Column(
                children: [
                  ElevatedButton(onPressed: () {}, child: const Text('Skip')),
                ],
              ),
        ),
      ),
    );

    testWidgets('orphaned focus is repaired by a click on the panel', (
      tester,
    ) async {
      await tester.pumpWidget(build());
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue, reason: 'autofocus');

      // What a desktop click on something unfocusable leaves behind: the
      // primary focus falls back to the enclosing route scope, which sits
      // above this scope's Focus, so keys reach nothing here.
      node.unfocus();
      await tester.pump();
      expect(keyboardFocusIsOrphaned(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      expect(seen, isEmpty, reason: 'nothing below the route scope sees keys');

      // A click on a button: the button wins the gesture arena, so this has
      // to work from the pointer event itself, not from a tap callback.
      await tester.tap(find.text('Skip'));
      await tester.pump();

      expect(node.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      expect(seen, [LogicalKeyboardKey.keyS]);
    });

    testWidgets('clicking another field still lands typing in that field', (
      tester,
    ) async {
      final a = FocusNode(debugLabel: 'a');
      final b = FocusNode(debugLabel: 'b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await tester.pumpWidget(
        build(
          child: Column(
            children: [
              TextField(focusNode: a),
              TextField(focusNode: b),
            ],
          ),
        ),
      );
      await tester.pump();

      a.requestFocus();
      await tester.pump();
      expect(a.hasFocus, isTrue);

      // The repair grabs the keyboard the moment the first field drops it, so
      // it must not outlive the click: the field the user actually clicked
      // ends up with focus, not the panel.
      await tester.tap(find.byType(TextField).last);
      await tester.pump();

      expect(b.hasPrimaryFocus, isTrue);
      expect(node.hasPrimaryFocus, isFalse);
    });
  });
}
