import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/top_bar.dart';
import 'package:chess_auto_prep/ui/status_bar.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget bar({required bool problem}) =>
      StatusBar('Saved a copy as Main (2)', problem: problem, onClose: () {});

  Future<Color?> ink(WidgetTester tester, {required bool problem}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: bar(problem: problem)),
      ),
    );
    return tester
        .widget<Text>(find.text('Saved a copy as Main (2)'))
        .style
        ?.color;
  }

  testWidgets('a problem is written in the error colour, on no fill', (
    tester,
  ) async {
    expect(await ink(tester, problem: true), darkTheme().colorScheme.error);
    expect(
      find.descendant(
        of: find.byType(StatusBar),
        matching: find.byWidgetPredicate(
          (widget) => widget is Container && widget.color != null,
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('an outcome the user asked for gets no alarm colour', (
    tester,
  ) async {
    expect(
      await ink(tester, problem: false),
      darkTheme().colorScheme.onSurface,
    );
  });

  testWidgets('a sentence in the top bar leaves the bar\'s height alone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<double> height(Widget? status) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                TopBar(
                  mode: Mode.pgnViewer,
                  onMode: (_) {},
                  offered: (_) => true,
                  onSettings: () {},
                  listShown: true,
                  onToggleList: () {},
                  actions: () => const [],
                  actionsChange: ChangeNotifier(),
                  status: status,
                ),
              ],
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(TopBar)).height;
    }

    final quiet = await height(null);
    final saying = await height(
      StatusBar(
        'The clipboard holds no FEN. ' * 20,
        action: (label: 'Retry', onPressed: () {}),
        onClose: () {},
      ),
    );
    expect(saying, quiet);
    expect(tester.takeException(), isNull);
  });
}
