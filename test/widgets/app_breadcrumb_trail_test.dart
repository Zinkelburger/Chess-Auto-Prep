import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/app_breadcrumb_trail.dart';

/// The trail lives inside every screen's app bar now, so its failure mode is
/// no longer "an ugly strip" but "it squeezed the title until something
/// overflowed". These tests pin the rules that prevent that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppHistory> pumpBar(
    WidgetTester tester, {
    required double width,
    Widget title = const Text('PGN Viewer'),
  }) async {
    final appState = AppState();
    final history = AppHistory(appState);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: appState),
          ChangeNotifierProvider<AppHistory>.value(value: history),
        ],
        child: MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              child: Scaffold(
                appBar: AppBar(title: AppBarTitleWithTrail(title: title)),
                body: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    return history;
  }

  testWidgets('at the root the title renders alone', (tester) async {
    await pumpBar(tester, width: 900);

    expect(find.text('PGN Viewer'), findsOneWidget);
    // Only crumb would be the mode root, which repeats the title.
    expect(find.byType(AppBreadcrumbTrail), findsNothing);
  });

  testWidgets('a deeper trail renders beside the title', (tester) async {
    final history = await pumpBar(tester, width: 900);

    history.recordPush(AppMode.pgnViewer, null, 'Game 12 vs foo');
    await tester.pump();

    expect(find.text('PGN Viewer'), findsOneWidget);
    expect(find.text('Tactics'), findsOneWidget);
    expect(find.text('Game 12 vs foo'), findsOneWidget);
  });

  testWidgets('a narrow bar drops the trail rather than squeeze the title', (
    tester,
  ) async {
    final history = await pumpBar(tester, width: 400);

    history.recordPush(AppMode.pgnViewer, null, 'Game 12 vs foo');
    await tester.pump();

    expect(find.text('PGN Viewer'), findsOneWidget);
    expect(find.text('Game 12 vs foo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clicking an earlier crumb pops back to it', (tester) async {
    final history = await pumpBar(tester, width: 900);

    history.recordPush(AppMode.pgnViewer, null, 'Game 12 vs foo');
    await tester.pump();
    expect(history.length, 2);

    await tester.tap(find.text('Tactics'));
    await tester.pump();

    expect(history.length, 1);
    expect(history.entries.single.mode, AppMode.tactics);
  });

  testWidgets('the current crumb is not clickable', (tester) async {
    final history = await pumpBar(tester, width: 900);

    history.recordPush(AppMode.pgnViewer, null, 'Game 12 vs foo');
    await tester.pump();

    await tester.tap(find.text('Game 12 vs foo'));
    await tester.pump();

    expect(history.length, 2);
  });

  testWidgets('a wide title with a long trail does not overflow', (
    tester,
  ) async {
    final history = await pumpBar(
      tester,
      width: 600,
      // The shape that overflowed in the first version: a min-size row whose
      // trailing icon cannot shrink.
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text('A rather long repertoire chapter name')),
          Icon(Icons.arrow_drop_down),
        ],
      ),
    );

    for (var i = 0; i < 6; i++) {
      history.recordPush(AppMode.repertoire, null, 'Crumb number $i');
    }
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
