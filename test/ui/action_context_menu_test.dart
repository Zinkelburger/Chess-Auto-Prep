import 'package:chess_auto_prep/ui/action_context_menu.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The right-click menu: there in the first frame, each action's symbol in
/// one slot before its label.
void main() {
  testWidgets('opens at once, symbols in a slot that lines the labels up', (
    tester,
  ) async {
    final taken = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    showActionContextMenu(context, const Offset(100, 100), [
                      AppAction(
                        'Copy line PGN',
                        () => taken.add('copy'),
                        icon: Icons.content_copy,
                      ),
                      AppAction('Plain', () => taken.add('plain')),
                    ]),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    // No fade or grow: nothing is left to animate after one frame.
    expect(find.text('Copy line PGN'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Plain')).dx,
      tester.getTopLeft(find.text('Copy line PGN')).dx,
    );
    expect(
      tester.getSize(find.byType(PopupMenuItem<VoidCallback>).first).height,
      menuRowHeight,
    );
    await tester.tap(find.text('Copy line PGN'));
    await tester.pumpAndSettle();
    expect(taken, ['copy']);
  });

  testWidgets('a menu without symbols keeps no slot for them', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showActionContextMenu(
                  context,
                  const Offset(100, 100),
                  [AppAction('Plain', () {})],
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    final item = find.byType(PopupMenuItem<VoidCallback>);
    expect(
      tester.getTopLeft(find.text('Plain')).dx - tester.getTopLeft(item).dx,
      Space.l,
    );
  });

  test('a label names its key after it, and only when it has one', () {
    expect(withKey('Flip board', 'F'), 'Flip board (F)');
    expect(withKey('Flip board', null), 'Flip board');
  });
}
