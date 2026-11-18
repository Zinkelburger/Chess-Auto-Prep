// The workspace's wiring: the engine starts again only for a change to
// which engine it is, its threads or its table, not for more lines.
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' show Opened;
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';
import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Show threat enables the threat on the Analysis tab', (
    tester,
  ) async {
    final w = WindowFixture(
      launchEngine: ({required cores, required memoryMb}) async =>
          Started(ScriptedEngine()),
    );
    addTearDown(w.dispose);
    await w.parts.start();
    await w.parts.resumed;
    final collection = collectionRef('Games');
    w.store.documents[collection] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.requests.openFile(collection, game: 0);
    expect(w.session.source, collection);
    final inspection = w.parts.workspace.inspection!;
    expect(await inspection.show(), isTrue);
    final displayed = w.parts.workspace.inspecting;
    final settingsOpen = ValueNotifier(false);
    addTearDown(settingsOpen.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: EnginePane(
            session: displayed.session,
            analysis: displayed.analysis,
            settings: displayed.settings,
            coresAvailable: displayed.coresAvailable,
            settingsOpen: settingsOpen,
          ),
        ),
      ),
    );
    expect(inspection.engine.enabled, isTrue);
    await tester.tap(find.byTooltip('Show threat'));
    await tester.pumpAndSettle();
    expect(displayed.settings.value.engineThreat, isTrue);
    expect(inspection.engine.threatShown, isTrue);
    expect(find.byTooltip('Hide threat'), findsOneWidget);
  });

  test('the engine starts again for new threads, not for more lines', () async {
    var launches = 0;
    final w = WindowFixture(
      launchEngine: ({required cores, required memoryMb}) async {
        launches++;
        return Started(ScriptedEngine());
      },
    );
    addTearDown(w.dispose);
    await w.parts.start();
    await w.analysis.enable();
    await pumpEventQueue();
    expect(w.analysis.enabled, isTrue);
    final before = launches;
    expect(before, greaterThan(0));
    final settings = w.settings;
    await settings.update(
      settings.value.copyWith(engineLines: settings.value.engineLines + 1),
    );
    await pumpEventQueue();
    expect(launches, before, reason: 'more lines start nothing');
    await settings.update(
      settings.value.copyWith(engineCores: settings.value.engineCores + 1),
    );
    await pumpEventQueue();
    expect(launches, greaterThan(before));
  });
}
