/// The eval-sources pane shows the lookup chain, not a list of checkboxes.
///
/// Its whole job is to answer two questions a build cannot answer for you —
/// which databases are on this machine, and which of them the next build will
/// actually ask — so these pin that the four steps render in chain order and
/// that each one offers the way to get it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/widgets/generation/eval_sources_controller.dart';
import 'package:chess_auto_prep/widgets/generation/eval_sources_section.dart';

Future<void> _pump(
  WidgetTester tester,
  EvalSourcesController controller, {
  bool cdbDirectAvailable = true,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<EvalDatabaseSettings>.value(
      value: EvalDatabaseSettings.instance,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EvalSourcesSection(
              controller: controller,
              isGenerating: false,
              cdbDirectAvailable: cdbDirectAvailable,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EvalSourcesController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = EvalSourcesController();
  });
  tearDown(() => controller.dispose());

  testWidgets('every source in the chain is named, in order', (tester) async {
    await _pump(tester, controller);

    const titles = [
      'Local ChessDB dump (chessdb.cn)',
      'ChessDB slice (.db file)',
      'Lichess cloud evaluations',
      'ChessDB API (chessdb.cn)',
    ];
    for (final title in titles) {
      expect(find.text(title), findsOneWidget, reason: title);
    }

    // Down the page in the order resolveEvalChain asks them — the order is
    // the behaviour, since the first hit ends the search.
    final tops = [
      for (final title in titles) tester.getTopLeft(find.text(title)).dy,
    ];
    expect(tops, orderedEquals(<double>[...tops]..sort()));
  });

  testWidgets('both downloadable databases offer a way to get them', (
    tester,
  ) async {
    await _pump(tester, controller);

    expect(find.text('Download database…'), findsOneWidget);
    expect(find.text('Download evaluations…'), findsOneWidget);
  });

  testWidgets('the dump collapses to one line without the native reader', (
    tester,
  ) async {
    await _pump(tester, controller, cdbDirectAvailable: false);

    expect(find.text('Local ChessDB dump (chessdb.cn)'), findsOneWidget);
    expect(
      find.text('Download database…'),
      findsNothing,
      reason: 'nothing on this machine could read the result',
    );
    // The rest of the chain is unaffected.
    expect(find.text('Download evaluations…'), findsOneWidget);
  });

  testWidgets('the Lichess switch stays off until a store is built', (
    tester,
  ) async {
    await _pump(tester, controller);

    final lichessSwitch = tester.widgetList<Switch>(find.byType(Switch));
    expect(
      lichessSwitch.every((s) => s.onChanged == null),
      isTrue,
      reason:
          'neither big database is set up in a test, so neither may be armed',
    );
  });
}
