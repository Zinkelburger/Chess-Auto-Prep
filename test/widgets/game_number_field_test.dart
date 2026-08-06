import 'package:chess_auto_prep/widgets/game_number_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host that owns the current index the way the nav bar's parent does, so the
/// box is tested against real "jump, then the counter follows" behaviour.
class _Host extends StatefulWidget {
  final int initialIndex;
  final int gameCount;
  final void Function(int)? onGoToGame;
  final String? tooltip;

  const _Host({
    this.initialIndex = 0,
    this.gameCount = 312,
    this.onGoToGame,
    this.tooltip,
  });

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int _index = widget.initialIndex;

  void goTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: GameNumberField(
        currentIndex: _index,
        gameCount: widget.gameCount,
        tooltip: widget.tooltip,
        onGoToGame: (i) {
          widget.onGoToGame?.call(i);
          goTo(i);
        },
      ),
    ),
  );
}

Future<void> _enter(WidgetTester tester, String text) async {
  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  group('GameNumberField', () {
    testWidgets('shows the current game number and the total', (tester) async {
      await tester.pumpWidget(const _Host(initialIndex: 69, gameCount: 312));

      expect(_fieldText(tester), '70');
      expect(find.text('Game'), findsOneWidget);
      expect(find.text('of 312'), findsOneWidget);
    });

    testWidgets('typing a number and submitting jumps straight there', (
      tester,
    ) async {
      final jumps = <int>[];
      await tester.pumpWidget(_Host(gameCount: 312, onGoToGame: jumps.add));

      await _enter(tester, '70');

      expect(jumps, [69]);
      expect(_fieldText(tester), '70');
    });

    testWidgets('a number past the end lands on the last game', (tester) async {
      final jumps = <int>[];
      await tester.pumpWidget(_Host(gameCount: 312, onGoToGame: jumps.add));

      await _enter(tester, '9999');

      expect(jumps, [311]);
      expect(_fieldText(tester), '312');
    });

    testWidgets('empty input navigates nowhere and restores the counter', (
      tester,
    ) async {
      final jumps = <int>[];
      await tester.pumpWidget(
        _Host(initialIndex: 4, gameCount: 312, onGoToGame: jumps.add),
      );

      await _enter(tester, '');

      expect(jumps, isEmpty);
      expect(_fieldText(tester), '5');
    });

    testWidgets('follows the game changing elsewhere while unfocused', (
      tester,
    ) async {
      await tester.pumpWidget(const _Host(gameCount: 312));
      final host = tester.state<_HostState>(find.byType(_Host));

      host.goTo(41);
      await tester.pump();

      expect(_fieldText(tester), '42');
    });

    testWidgets('does not overwrite a number being typed', (tester) async {
      await tester.pumpWidget(const _Host(gameCount: 312));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '12');

      tester.state<_HostState>(find.byType(_Host)).goTo(41);
      await tester.pump();

      expect(_fieldText(tester), '12');
    });

    testWidgets('stays typable through its tooltip wrapper', (tester) async {
      final jumps = <int>[];
      await tester.pumpWidget(
        _Host(
          gameCount: 312,
          onGoToGame: jumps.add,
          tooltip: 'Game 1 of 312, in file order.',
        ),
      );

      await _enter(tester, '7');

      expect(jumps, [6]);
    });

    testWidgets('is disabled with no games', (tester) async {
      await tester.pumpWidget(const _Host(gameCount: 0));

      expect(_fieldText(tester), '');
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('of 0'), findsOneWidget);
    });
  });
}
