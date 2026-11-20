// The workspace's wiring: the engine starts again only for a change to
// which engine it is, its threads or its table, not for more lines.
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/explorer_answer.dart';
import 'package:chess_auto_prep/chess/explorer_choice.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' show Opened;
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_pane.dart';
import 'package:chess_auto_prep/workspace/explorer/explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/profile/profile.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Explorer lists and opens the replacement TWIC game under its own name',
    () async {
      final profile = await Profile.temporary();
      addTearDown(profile.dispose);
      final path = profile.supportFile('master_games.db');
      final w = WindowFixture(masterGames: path);
      addTearDown(w.dispose);
      await w.parts.start();
      await w.parts.resumed;
      final databases = w.parts.databases;

      Future<void> importGame(String white, String moves) async {
        final file = File(profile.document('$white.pgn'));
        await file.writeAsString(
          '[Event "Club"]\n[White "$white"]\n[Black "Bob"]\n[Result "1-0"]\n\n'
          '$moves 1-0\n',
        );
        w.viewerPicker.answer = file.path;
        await databases.importFile();
        expect(databases.problem, isNull);
        expect(databases.page.games.single.white, white);
      }

      final explorer = w.explorer;
      late Completer<ExplorerState> ready;
      void changed() {
        final state = explorer.state;
        if (state is! ExplorerAsking && !ready.isCompleted) {
          ready.complete(state);
        }
      }

      Future<ExplorerGame> visitExplorer() async {
        ready = Completer<ExplorerState>();
        explorer.addListener(changed);
        final state = await ready.future;
        expect(state, isA<ExplorerShown>());
        return (state as ExplorerShown).answer.games.single;
      }

      await importGame('Alice', '1. e4 e5');
      final originalId = databases.page.games.single.id;
      await w.requests.open(benkoMain);
      explorer.choose(const ExplorerChoice(source: ExplorerSource.twic));
      expect((await visitExplorer()).white, 'Alice');

      explorer.removeListener(changed);
      w.requests.switchTo(Mode.databases);
      await databases.remove((
        name: 'Master games',
        path: path,
        bytes: databases.size.bytes,
        removable: true,
      ));
      expect(databases.page.games, isEmpty);
      await importGame('Clara', '1. d4 d5');
      expect(databases.page.games.single.id, originalId);

      w.requests.switchTo(Mode.repertoires);
      final listed = await visitExplorer();
      await w.requests.openExplorerGame(
        listed,
        source: explorer.choice.source,
        ply: explorer.ply,
      );
      explorer.removeListener(changed);
      final opened = w.session.source!;
      final pgn = (w.store.documents[opened] as Opened).text;
      expect(pgn, contains('[White "Clara"]'));
      expect(listed.white, 'Clara');
      expect(opened.name, contains('Clara - Bob'));
    },
  );

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
