import 'dart:io';

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/engines/analysis_launch.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TournamentEngine engine({String? path, Map<String, Object?>? options}) =>
      TournamentEngine({
        'id': 'mine',
        'name': 'Mine',
        'executablePath': ?path,
        'arguments': ['--uci'],
        'threads': 2,
        'hashMb': 64,
        'ponder': true,
        'options': ?options,
      });

  test('only an engine that names its own program analyses the board', () {
    expect(analysesBoard(engine(path: '/opt/engines/mine')), isTrue);
    expect(analysesBoard(engine(path: '   ')), isFalse);
    expect(analysesBoard(engine()), isFalse);
  });

  test('the analysis keeps an engine\'s own options and sets its own '
      'threads and table, without pondering', () {
    final options = analysisOptions(
      engine(path: '/opt/engines/mine', options: {'Skill Level': 12}),
      cores: 6,
      memoryMb: 512,
    );
    expect(options['Skill Level'], '12');
    expect(options['Threads'], '6');
    expect(options['Hash'], '512');
    expect(options.containsKey('Ponder'), isFalse);
  });

  test('an engine with no program is refused, and one with a program is '
      'started from it', () async {
    final started = <(String, List<String>)>[];
    final engines = EngineSupervisor(
      startProcess:
          (
            executable,
            arguments, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            mode = ProcessStartMode.normal,
          }) async {
            started.add((executable, arguments));
            throw const ProcessException('mine', [], 'not here');
          },
    );
    final none = await launchAnalysisEngine(
      engine(path: '  '),
      engines: engines,
      cores: 1,
      memoryMb: 16,
    );
    expect((none as StartFailed).reason, 'Mine names no program.');
    expect(started, isEmpty);
    await launchAnalysisEngine(
      engine(path: ' mine-engine '),
      engines: engines,
      cores: 1,
      memoryMb: 16,
    );
    expect(started.single.$1, 'mine-engine');
    expect(started.single.$2, ['--uci']);
  });

  test('an engine is sent only the options it lists, so one without Threads '
      'still starts', () async {
    final folder = await Directory.systemTemp.createTemp('analysis_engine');
    addTearDown(() => folder.delete(recursive: true));
    final heard = File('${folder.path}/heard');
    final script = File('${folder.path}/engine')
      ..writeAsStringSync('''#!/bin/sh
while read -r line; do
  echo "\$line" >> "${heard.path}"
  case "\$line" in
    uci) echo "id name Listed"; echo "option name Hash type spin default 16 min 1 max 1024"; echo "uciok" ;;
    isready) echo "readyok" ;;
    quit) exit 0 ;;
  esac
done
''');
    await Process.run('chmod', ['+x', script.path]);
    final engines = EngineSupervisor();
    addTearDown(engines.dispose);
    final start = await launchAnalysisEngine(
      engine(path: script.path),
      engines: engines,
      cores: 3,
      memoryMb: 64,
    );
    final started = start as Started;
    await started.engine.quit();
    final lines = heard.readAsLinesSync();
    expect(lines, contains('setoption name Hash value 64'));
    expect(lines.where((line) => line.contains('Threads')), isEmpty);
  }, skip: !Platform.isLinux);
}
