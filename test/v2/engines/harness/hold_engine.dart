// Run by stockfish_exit_test.dart as a separate process, standing in for
// the app: starts the engine under a supervisor, sets it searching, prints
// the engine's pid, then waits to be killed.
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';

Future<void> main(List<String> args) async {
  final engines = EngineSupervisor();
  final start = await engines.start(args.single, options: {'Hash': '16'});
  if (start case StartFailed(:final reason)) {
    stderr.writeln(reason);
    exit(2);
  }
  (start as Started).engine.analyse(Fen.initial, multiPv: 1);
  stdout.writeln('pid ${engines.pids.single}');
  await stdout.flush();
  await Future<void>.delayed(const Duration(minutes: 5));
}
