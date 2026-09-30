// A line move killed while its recovery put its source back, or right after
// its recovery moved its training rows again over an answer written while
// it waited: the next starts finish what it began, once.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _sourceBefore =
    '[Event "Move me"]\n\n1. e4 *\n\n[Event "Stay"]\n\n1. c4 *\n';

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late File source;
  late File target;

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp('compound-follow-');
    root = Directory(temporary.resolveSymbolicLinksSync());
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    source = await File(
      p.join(documents.path, 'Source.pgn'),
    ).writeAsString(_sourceBefore);
    target = await File(
      p.join(documents.path, 'Target.pgn'),
    ).writeAsString('[Event "Target"]\n\n1. d4 *\n');
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> killAt(String scenario) async {
    final folder = await Directory(
      p.join(Directory.current.path, '.dart_tool'),
    ).createTemp('compound-follow-process-');
    addTearDown(() => folder.delete(recursive: true));
    final script = await File(
      p.join(folder.path, 'follow.dart'),
    ).writeAsString(_driver);
    final process = await Process.start('dart', [
      'run',
      '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
      script.path,
      documents.path,
      support.path,
      source.path,
      target.path,
      scenario,
    ], workingDirectory: Directory.current.path);
    final said = StringBuffer();
    final ready = Completer<void>();
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          said.writeln(line);
          if (line == 'checkpoint durable' && !ready.isCompleted) {
            ready.complete();
          }
        });
    final errors = process.stderr.transform(utf8.decoder).listen(said.write);
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Child exited $code: $said'));
        }
      }),
    );
    try {
      await ready.future.timeout(const Duration(seconds: 60));
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 10));
      await output.cancel();
      await errors.cancel();
    }
  }

  Future<void> restartTwice() async {
    for (var i = 0; i < 2; i++) {
      await CompoundWrites(documents: documents, support: support).recover();
    }
  }

  List<FileSystemEntity> under(String folder) {
    final directory = Directory(p.join(support.path, folder));
    return directory.existsSync()
        ? directory.listSync(recursive: true).whereType<File>().toList()
        : const [];
  }

  test('killed while putting the source back, it is set aside once', () async {
    await killAt('putBack');
    // The source is back; its record was not set aside yet.
    expect(await source.readAsBytes(), utf8.encode(_sourceBefore));
    expect(under(CompoundWrites.journal), hasLength(1));
    await restartTwice();
    expect(await source.readAsBytes(), utf8.encode(_sourceBefore));
    expect(await target.readAsString(), _edited);
    expect(under(CompoundWrites.journal), isEmpty);
    expect(under('recovery-quarantine'), hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test(
    'killed after moving the rows again over an answer, they move once',
    () async {
      String row(String path, String at) => '$path,line,$at,good,false,trainer';
      final history = File(p.join(documents.path, historyFile));
      final other = p.join(documents.path, 'Other.pgn');
      await history.writeAsString(
        '$historyHeader\n${row(source.path, '2026-09-24T00:00:00Z')}\n'
        '${row(other, '2026-09-25T00:00:00Z')}\n',
      );
      await File(
        p.join(documents.path, streaksFile),
      ).writeAsString('$streaksHeader\n${source.path},line,0,3,true\n');
      await killAt('training');
      expect(under(CompoundWrites.journal), hasLength(1));
      await restartTwice();
      expect(under(CompoundWrites.journal), isEmpty);
      expect(under('recovery-quarantine'), isEmpty);
      expect(
        await history.readAsString(),
        '$historyHeader\n${row(target.path, '2026-09-24T00:00:00Z')}\n'
        '${row(other, '2026-09-25T00:00:00Z')}\n'
        '${row(target.path, '2026-09-29T07:00:00Z')}\n',
      );
      expect(
        await File(p.join(documents.path, streaksFile)).readAsString(),
        '$streaksHeader\n${target.path},line,0,3,true\n',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

const _edited = '[Event "Edited elsewhere"]\n\n1. a3 *\n';

const _driver = r'''
import 'dart:io';
import 'package:chess_auto_prep/storage/compound_commit.dart';
import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/line_progress.dart';
import 'package:chess_auto_prep/storage/operation_journal.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';

Future<void> main(List<String> args) async {
  final documents = Directory(args[0]);
  final support = Directory(args[1]);
  final (source, target, scenario) = (args[2], args[3], args[4]);
  Future<void> checkpoint() async {
    stdout.writeln('checkpoint durable');
    await Future<void>.delayed(const Duration(minutes: 5));
  }

  final sourceBefore = await File(source).readAsString();
  final targetBefore = await File(target).readAsString();
  final training = scenario == 'training'
      ? await lineProgressPlan(documents, from: source, to: target,
          ids: const {'line': 'line'})
      : const <CompoundTraining>[];
  final command = CompoundCommit.pair(
    id: 'follow',
    training: training,
    primary: CompoundDocument(path: source, before: sourceBefore,
      after: '[Event "Stay"]\n\n1. c4 *\n'),
    secondary: CompoundDocument(path: target, before: targetBefore,
      after: '$targetBefore\n[Event "Move me"]\n\n1. e4 *\n'),
  );
  final stopped = CompoundWrites(documents: documents, support: support,
    testHook: (step) async {
      if (step == CompoundWriteStep.document) throw StateError('stopped');
    });
  if (await stopped.commit(command) is! Deferred) {
    throw StateError('The pair did not stop once its source was written.');
  }
  if (scenario == 'putBack') {
    await File(target).writeAsString('[Event "Edited elsewhere"]\n\n1. a3 *\n');
  } else {
    // The old app answers the moved line where it still is.
    await File('${documents.path}/$historyFile').writeAsString(
      '$source,line,2026-09-29T07:00:00Z,good,false,trainer\n',
      mode: FileMode.append);
  }
  await CompoundWrites(documents: documents, support: support,
    putBackHook: scenario == 'putBack' ? checkpoint : null,
    testHook: (step) async {
      if (scenario == 'training' && step == CompoundWriteStep.training) {
        await checkpoint();
      }
    }).recover();
  throw StateError('The recovery never reached its checkpoint.');
}
''';
