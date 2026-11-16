// The top bar's running task is a way back to it: the mode the job was
// started in, with the tab that shows it up, or the builder when that mode
// has no such tab; a tournament goes to its own mode.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/review/game_review_pane.dart';
import 'package:chess_auto_prep/workspace/search/search_pane.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  /// [kind] started while [mode] is up, then the user goes to Tactics and
  /// presses the running task.
  Future<void> detour(
    WidgetTester tester,
    EngineJobKind kind, {
    required Mode mode,
  }) async {
    await w.pumpShell(tester);
    w.requests.switchTo(mode);
    await tester.pumpAndSettle();
    final jobs = w.parts.workspace.jobs!;
    final owner = Object();
    jobs.take(owner, 'Working', kind: kind);
    addTearDown(() => jobs.release(owner));
    await tester.pumpAndSettle();
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    await tester.tap(find.text('${kind.label} · running'));
    await tester.pumpAndSettle();
  }

  testWidgets('goes back to the mode the job started in', (tester) async {
    await detour(tester, EngineJobKind.review, mode: Mode.pgnViewer);
    expect(w.requests.mode, Mode.pgnViewer);
    expect(find.byType(GameReviewPane), findsOneWidget);
  });

  testWidgets('goes to the builder when that mode has no tab for the job', (
    tester,
  ) async {
    await detour(tester, EngineJobKind.search, mode: Mode.pgnViewer);
    expect(w.requests.mode, Mode.repertoires);
    expect(find.byType(SearchPane), findsOneWidget);
  });

  testWidgets('lines being made show in the Search tab', (tester) async {
    await detour(tester, EngineJobKind.makingLines, mode: Mode.repertoires);
    expect(w.requests.mode, Mode.repertoires);
    expect(find.byType(SearchPane), findsOneWidget);
  });

  testWidgets('a tournament goes to its own mode', (tester) async {
    await detour(tester, EngineJobKind.tournament, mode: Mode.repertoires);
    expect(w.requests.mode, Mode.engineTournament);
  });
}
