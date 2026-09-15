import 'dart:async';

import 'package:chess_auto_prep/utils/app_shortcuts.dart';
import 'package:chess_auto_prep/utils/keyboard_shortcut_utils.dart';
import 'package:chess_auto_prep/widgets/board_keyboard_scope.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests send physical keys and platform text input separately. Model
/// the desktop contract: only an unhandled character reaches the text client.
Future<void> typeKey(
  WidgetTester tester,
  LogicalKeyboardKey key,
  String character,
) async {
  final handled = await tester.sendKeyDownEvent(key, character: character);
  if (!handled && tester.testTextInput.hasAnyClients) {
    final editor = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .singleWhere((widget) => widget.focusNode.hasFocus);
    final value = editor.controller.value;
    final selection = value.selection;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(
          selection.start,
          selection.end,
          character,
        ),
        selection: TextSelection.collapsed(
          offset: selection.start + character.length,
        ),
      ),
    );
  }
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

void desktopTest(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}

void main() {
  late GlobalKey<MoveInputWidgetState> moveKey;
  late FocusScopeNode scope;
  late FocusNode button;
  late TextEditingController notes;
  late List<String> moves;
  late int next;
  late int flip;
  late int reveal;
  late int modified;
  late bool enabled;
  late StateSetter rebuild;
  late BuildContext screenContext;

  setUp(() {
    moveKey = GlobalKey<MoveInputWidgetState>();
    scope = FocusScopeNode();
    button = FocusNode();
    notes = TextEditingController();
    moves = [];
    next = flip = reveal = modified = 0;
    enabled = true;
    addTearDown(scope.dispose);
    addTearDown(button.dispose);
    addTearDown(notes.dispose);
  });

  Widget build() => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.linux),
    home: StatefulBuilder(
      builder: (context, setState) {
        rebuild = setState;
        screenContext = context;
        return BoardKeyboardScope(
          focusNode: scope,
          moveInputKey: moveKey,
          bindings: () => [
            ...KeyBinding.forShortcut(
              AppShortcut.forwardOneMove,
              'Next move',
              () => next++,
              repeats: true,
            ),
            ...KeyBinding.forShortcut(
              AppShortcut.flipBoard,
              'Flip',
              () => flip++,
            ),
            ...KeyBinding.forShortcut(
              AppShortcut.toggleSolution,
              'Reveal',
              () => reveal++,
            ),
            KeyBinding.run(
              LogicalKeyboardKey.keyE,
              'Modified command',
              () => modified++,
              control: true,
            ),
          ],
          child: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  key: Key('board'),
                  height: 160,
                  width: 200,
                  child: ColoredBox(color: Colors.grey),
                ),
                MoveInputWidget(
                  key: moveKey,
                  position: Chess.initial,
                  enabled: enabled,
                  onMove: (move) => moves.add(move.san),
                ),
                TextField(key: const Key('notes'), controller: notes),
                AppOverflowMenu(
                  entries: [AppMenuEntry(label: 'Menu command', onRun: () {})],
                ),
                TextButton(
                  focusNode: button,
                  onPressed: () {},
                  child: const Text('Panel button'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  desktopTest(
    'typing from scope or a sibling button keeps the first character exactly once',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.pump();
      expect(moveKey.currentState!.hasFocus, isFalse);
      await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        'e',
      );
      await typeKey(tester, LogicalKeyboardKey.digit4, '4');
      expect(moves, ['e4']);
      button.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await typeKey(tester, LogicalKeyboardKey.keyN, 'N');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await typeKey(tester, LogicalKeyboardKey.keyF, 'f');
      await typeKey(tester, LogicalKeyboardKey.digit3, '3');
      expect(moves, ['e4', 'Nf3']);
      expect(flip, 0);
    },
  );

  desktopTest(
    'board click after another editor and Escape both leave typing reachable',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.enterText(find.byKey(const Key('notes')), 'notes');
      await tester.tap(
        find.byKey(const Key('board')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(scope.hasPrimaryFocus, isTrue);
      await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(scope.hasPrimaryFocus, isTrue);
      await typeKey(tester, LogicalKeyboardKey.keyD, 'd');
      await typeKey(tester, LogicalKeyboardKey.digit4, '4');
      expect(moves, ['d4']);
      expect(notes.text, 'notes');
    },
  );

  desktopTest(
    'other editors own letters, space, arrows and focus during enablement',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.tap(find.byKey(const Key('notes')));
      await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
      await typeKey(tester, LogicalKeyboardKey.keyF, 'f');
      await typeKey(tester, LogicalKeyboardKey.space, ' ');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      rebuild(() => enabled = false);
      await tester.pump();
      rebuild(() => enabled = true);
      await tester.pump();
      moveKey.currentState!
          .focus(); // asynchronous host callbacks must respect editing
      await tester.pump();
      expect(notes.text, 'ef ');
      expect(moveKey.currentState!.hasFocus, isFalse);
      expect([flip, reveal, next], [0, 0, 0]);
      expect(moves, isEmpty);
    },
  );

  desktopTest(
    'empty field navigates including repeats; partial text keeps caret editing',
    (tester) async {
      await tester.pumpWidget(build());
      moveKey.currentState!.focus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(next, 2);
      await typeKey(tester, LogicalKeyboardKey.keyN, 'N');
      await typeKey(tester, LogicalKeyboardKey.keyB, 'b');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      final editor = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(editor.controller.selection.baseOffset, 1);
      expect(next, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(reveal, 1);
      expect(editor.controller.text, 'Nb');
    },
  );

  desktopTest(
    'disabled input leaves command letters available and never collects moves',
    (tester) async {
      enabled = false;
      await tester.pumpWidget(build());
      await tester.pump();
      await typeKey(tester, LogicalKeyboardKey.keyF, 'f');
      expect(flip, 1);
      expect(moveKey.currentState!.hasFocus, isFalse);
      expect(moves, isEmpty);
    },
  );

  desktopTest('modifier chords are not converted to moves', (tester) async {
    await tester.pumpWidget(build());
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE, character: 'e');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(modified, 1);
    expect(moveKey.currentState!.hasFocus, isFalse);
  });

  desktopTest('Tab and Shift+Tab traverse normally', (tester) async {
    await tester.pumpWidget(build());
    moveKey.currentState!.focus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(moveKey.currentState!.hasFocus, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(moveKey.currentState!.hasFocus, isTrue);
  });

  desktopTest(
    'dialog keys cannot type into the board behind it; closing restores typing',
    (tester) async {
      await tester.pumpWidget(build());
      await tester.pump();
      unawaited(
        showDialog<void>(
          context: screenContext,
          builder: (context) => AlertDialog(
            content: const Text('Dialog'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(reveal, 0);
      expect(moveKey.currentState!.hasFocus, isFalse);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
      await typeKey(tester, LogicalKeyboardKey.digit4, '4');
      expect(moves, ['e4']);
    },
  );
  desktopTest(
    'a hidden mode cannot capture moves; switching back restores typing',
    (tester) async {
      final secondKey = GlobalKey<MoveInputWidgetState>();
      var mode = 0;
      late StateSetter switchMode;
      final received = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              switchMode = setState;
              return IndexedStack(
                index: mode,
                children: [
                  for (var i = 0; i < 2; i++)
                    TickerMode(
                      enabled: mode == i,
                      child: BoardKeyboardScope(
                        moveInputKey: i == 0 ? moveKey : secondKey,
                        bindings: () => [],
                        child: Scaffold(
                          body: MoveInputWidget(
                            key: i == 0 ? moveKey : secondKey,
                            position: Chess.initial,
                            onMove: (_) => received.add(i),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pump();
      await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
      await typeKey(tester, LogicalKeyboardKey.digit4, '4');
      switchMode(() => mode = 1);
      await tester.pumpAndSettle();
      moveKey.currentState!.focus();
      await typeKey(tester, LogicalKeyboardKey.keyD, 'd');
      await typeKey(tester, LogicalKeyboardKey.digit4, '4');
      switchMode(() => mode = 0);
      await tester.pumpAndSettle();
      await typeKey(tester, LogicalKeyboardKey.keyC, 'c');
      await typeKey(tester, LogicalKeyboardKey.digit4, '4');
      expect(received, [0, 1, 0]);
    },
  );

  desktopTest('refocusing a partial move inserts at the existing selection', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await tester.pump();
    await typeKey(tester, LogicalKeyboardKey.keyN, 'N');
    await typeKey(tester, LogicalKeyboardKey.keyB, 'b');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    button.requestFocus();
    await tester.pump();
    await typeKey(tester, LogicalKeyboardKey.keyF, 'f');
    final editor = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editor.controller.text, 'Nfb');
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 2),
    );
  });

  desktopTest('zero and numpad ranks route into the move field', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await tester.pump();
    await typeKey(tester, LogicalKeyboardKey.numpad0, '0');
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller
          .text,
      '0',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      await tester.sendKeyEvent(LogicalKeyboardKey.numLock);
    }
    await typeKey(tester, LogicalKeyboardKey.numpad4, '4');
    expect(moves, ['e4']);
  });
  desktopTest('Escape leaves another editor so move typing can resume', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await tester.enterText(find.byKey(const Key('notes')), 'retain notes');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(scope.hasPrimaryFocus, isTrue);
    await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
    await typeKey(tester, LogicalKeyboardKey.digit4, '4');
    expect(moves, ['e4']);
    expect(notes.text, 'retain notes');
  });
  desktopTest('open anchored menus retain keys until dismissed', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await tester.pump();
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
    expect(moveKey.currentState!.hasFocus, isFalse);
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .controller
          .text,
      isEmpty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Menu command'), findsNothing);
    await typeKey(tester, LogicalKeyboardKey.keyE, 'e');
    await typeKey(tester, LogicalKeyboardKey.digit4, '4');
    expect(moves, ['e4']);
  });
}
