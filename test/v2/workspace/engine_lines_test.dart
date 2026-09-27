import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_engine.dart';
import '../support/session_fixture.dart';

void main() {
  test(
    'asking for more lines starts the search again with that many',
    () async {
      final fixture = await openSession(blackChapter);
      addTearDown(fixture.dispose);
      final engine = ScriptedEngine();
      final analysis = EngineAnalysis(
        fixture.session,
        () async => Started(engine),
        multiPv: 3,
      );
      addTearDown(analysis.dispose);
      await analysis.enable();
      expect(engine.current.multiPv, 3);
      analysis.setLines(5);
      expect(analysis.multiPv, 5);
      expect(engine.searches.length, 2);
      expect(engine.current.multiPv, 5);
      expect(engine.current.fen, fixture.session.fen);
      analysis.setLines(5);
      expect(
        engine.searches.length,
        2,
        reason: 'the same count again is nothing',
      );
    },
  );

  test('a restart quits the engine and starts another', () async {
    final fixture = await openSession(blackChapter);
    addTearDown(fixture.dispose);
    var started = 0;
    final analysis = EngineAnalysis(fixture.session, () async {
      started++;
      return Started(ScriptedEngine());
    });
    addTearDown(analysis.dispose);
    await analysis.restart();
    expect(started, 0, reason: 'off stays off');
    await analysis.enable();
    await analysis.restart();
    expect(started, 2);
    expect(analysis.enabled, isTrue);
  });
}
