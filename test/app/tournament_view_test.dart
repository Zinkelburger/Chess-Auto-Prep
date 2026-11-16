// The Engine tournament page: a new tournament only while none runs, the
// page taking the keys when it comes up, and the running task in the top
// bar leaving the selection alone when the run on the machine is not one
// of the page's.
import 'package:chess_auto_prep/app/job_door.dart';
import 'package:chess_auto_prep/app/mode_view.dart';
import 'package:chess_auto_prep/app/tournament_view.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_jobs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_tournaments.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  late TournamentRun run;
  setUp(() {
    final store = ScriptedTournaments();
    addTearDown(store.dispose);
    w = WindowFixture(
      tournaments: store,
      launchTournament: (_, _) async => const StartFailed('not launched'),
    );
    run = w.parts.tournaments!;
  });
  tearDown(() => w.dispose());

  TournamentView view() {
    final view = TournamentView(w.parts.workspace, run, w.requests);
    addTearDown(view.dispose);
    return view;
  }

  Future<List<AppAction>> actions(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final editing = ValueNotifier(false);
    addTearDown(editing.dispose);
    void none() {}
    final ModeMenu menu = (
      editing: editing,
      board: () => const [],
      dialogs: (
        saveCopy: none,
        saveHeld: none,
        exportPgn: none,
        search: none,
        accounts: none,
        newBook: none,
        importCourse: none,
      ),
      context: tester.element(find.byType(SizedBox)),
    );
    return view().actions(menu);
  }

  bool newOn(List<AppAction> actions) =>
      actions.singleWhere((a) => a.label == 'New tournament…').run != null;

  testWidgets('a new tournament is offered only while none runs', (
    tester,
  ) async {
    expect(newOn(await actions(tester)), isTrue);
    run.running = true;
    expect(newOn(await actions(tester)), isFalse);
  });

  testWidgets('the page takes the keys when it comes up', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: view().screen(const {})),
      ),
    );
    await tester.pump();
    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull);
    expect(
      focus!.context!.findAncestorWidgetOfExactType<Scaffold>(),
      isNotNull,
    );
  });

  test('the running task leaves the selection alone when the tournament '
      'on the machine is none of the list', () {
    Tournament match(String id) => Tournament({
      'id': id,
      'config': {'name': id},
      'games': <Object>[],
    });
    final second = match('second');
    run
      ..history = [match('first'), second]
      ..selected = second;
    final jobs = w.parts.workspace.jobs!;
    final owner = Object();
    jobs.take(owner, 'Engine tournament', kind: EngineJobKind.tournament);
    addTearDown(() => jobs.release(owner));
    JobDoor(
      jobs: jobs,
      requests: w.requests,
      views: const {},
      tournaments: run,
    ).show();
    expect(run.selected?.id, 'second');
  });
}
