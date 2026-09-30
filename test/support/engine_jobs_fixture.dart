import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';

import 'scripted_engine.dart';
import 'session_fixture.dart';

/// The machine's heavy-engine guard over a board engine on a scratch game,
/// for owners that take it (a tournament, a review) tested on their own.
Future<EngineJobs> engineJobsFixture() async {
  final board = await openSession('[Event "Board"]\n[Result "*"]\n\n*');
  return EngineJobs(
    EngineAnalysis(board.session, () async => Started(ScriptedEngine())),
  );
}
