@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final checkpoint in ['queued', 'reviews', 'completed']) {
    test(
      'SIGKILL after $checkpoint recovers frozen ratings and distinct answers once',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final child = await fixture.start(checkpoint);
        addTearDown(child.close);
        await fixture.expectCheckpoint(checkpoint);
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        expect(
          await child.process.exitCode.timeout(const Duration(seconds: 10)),
          isNot(0),
        );

        // A separate OS process opens the profile with no accepted token or
        // trainer state. A second new process must leave all bytes unchanged.
        await fixture.recover();
        await fixture.expectRecovered();
        final first = await fixture.snapshot();
        await fixture.recover();
        await fixture.expectRecovered();
        expect(await fixture.snapshot(), first);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

final class _Fixture {
  _Fixture(this.root, this.harness, this.documents, this.support, this.script);
  final Directory root;
  final Directory harness;
  final Directory documents;
  final Directory support;
  final File script;
  String get source => p.join(documents.path, 'Main.pgn');
  File get input => File(p.join(root.path, 'commands.json'));
  File participant(String name) => File(p.join(documents.path, name));
  File note(String id) =>
      File(p.join(support.path, 'training-writes', '$id.json'));
  String review(int count) =>
      '$source,line,Mainline,2.50,$count.00,,,,$count,0,false';
  String streak(int count) => '$source,line,0,$count,0';
  List<String> history(int count) => [
    source,
    'line',
    '2026-09-25T00:00:0$count.000Z',
    'good',
    '0',
    'trainer',
  ];
  String get attempt => encodeAttempt(
    Attempt(
      key: (source: source, id: 'line'),
      ply: 0,
      fen: Fen.initial,
      played: 'd4',
      expected: 'e4',
      correct: false,
      phase: AttemptPhase.learning,
      at: DateTime.utc(2026, 9, 25),
    ),
  );
  static const _ids = ['rating-a', 'rating-b', 'answer-a', 'answer-b'];

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('training-process-');
    final harness = await Directory(
      p.join(Directory.current.path, '.dart_tool'),
    ).createTemp('training-process-');
    final documents = await Directory(p.join(root.path, 'Documents')).create();
    final support = await Directory(p.join(root.path, 'Support')).create();
    final script = await File(
      p.join(harness.path, 'training.dart'),
    ).writeAsString(_driver);
    final f = _Fixture(root, harness, documents, support, script);
    await File(f.source).writeAsString('[Event "Main"]\n\n1. e4 *\n');
    await f
        .participant(reviewsFile)
        .writeAsString('$reviewsHeader\n${f.review(0)}\n');
    await f
        .participant(streaksFile)
        .writeAsString('$streaksHeader\n${f.streak(0)}\n');
    await f.participant(historyFile).writeAsString('$historyHeader\n');
    await f.participant(attemptsFile).writeAsString('');
    // B is frozen against A's projected after rows before A writes anything.
    // Equal-time equal-payload answers are still two accepted operations.
    final payloads = [
      for (final count in [1, 2])
        jsonEncode([
          'write',
          [
            [f.review(count - 1), f.review(count)],
          ],
          [
            [f.streak(count - 1), f.streak(count)],
          ],
          [f.history(count)],
        ]),
      jsonEncode(['attempt', f.attempt]),
      jsonEncode(['attempt', f.attempt]),
    ];
    await f.input.writeAsString(
      jsonEncode([
        for (var i = 0; i < payloads.length; i++)
          {
            'id': _ids[i],
            'payload': payloads[i],
            'predecessor': i == 0 ? null : _ids[i - 1],
          },
      ]),
    );
    return f;
  }

  List<String> arguments(String mode) => [
    'run',
    '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
    script.path,
    documents.path,
    support.path,
    source,
    input.path,
    mode,
  ];

  Future<_Child> start(String checkpoint) async {
    final process = await Process.start(
      'dart',
      arguments(checkpoint),
      workingDirectory: Directory.current.path,
    );
    final ready = Completer<void>();
    final diagnostics = StringBuffer();
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          diagnostics.writeln(line);
          if (line == 'checkpoint durable' && !ready.isCompleted)
            ready.complete();
        });
    final errors = process.stderr
        .transform(utf8.decoder)
        .listen(diagnostics.write);
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted)
          ready.completeError(StateError('Child exited $code: $diagnostics'));
      }),
    );
    final child = _Child(process, output, errors);
    try {
      await ready.future.timeout(const Duration(seconds: 45));
      return child;
    } on Object {
      await child.close();
      rethrow;
    }
  }

  Future<void> recover() async {
    final result = await Process.run(
      'dart',
      arguments('recover'),
      workingDirectory: Directory.current.path,
    ).timeout(const Duration(seconds: 30));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('recovered'));
  }

  Future<void> expectCheckpoint(String checkpoint) async {
    final states = [
      for (final id in _ids)
        (jsonDecode(await note(id).readAsString()) as Map)['state'],
    ];
    if (checkpoint == 'completed') {
      expect(states, everyElement('complete'));
      await expectRecovered();
      return;
    }
    expect(
      states,
      checkpoint == 'queued'
          ? ['queued', 'queued', 'queued', 'queued']
          : ['committing', 'queued', 'queued', 'queued'],
    );
    expect(
      await participant(reviewsFile).readAsString(),
      '$reviewsHeader\n${review(checkpoint == 'queued' ? 0 : 1)}\n',
    );
    expect(
      await participant(streaksFile).readAsString(),
      '$streaksHeader\n${streak(0)}\n',
    );
    expect(await participant(historyFile).readAsString(), '$historyHeader\n');
    expect(await participant(attemptsFile).readAsString(), isEmpty);
  }

  Future<void> expectRecovered() async {
    expect(
      await participant(reviewsFile).readAsString(),
      '$reviewsHeader\n${review(2)}\n',
    );
    expect(
      await participant(streaksFile).readAsString(),
      '$streaksHeader\n${streak(2)}\n',
    );
    expect(
      await participant(historyFile).readAsString(),
      '$historyHeader\n${history(1).join(',')}\n${history(2).join(',')}\n',
    );
    expect(
      await participant(attemptsFile).readAsString(),
      '$attempt\n$attempt\n',
    );
    expect(await File(source).readAsString(), '[Event "Main"]\n\n1. e4 *\n');
    for (final id in _ids) {
      final metadata = jsonDecode(await note(id).readAsString()) as Map;
      expect(metadata['state'], 'complete');
      expect(metadata['payload'], isNull);
      expect(metadata['files'], isNull);
    }
  }

  Future<Map<String, List<int>>> snapshot() async => {
    for (final name in [reviewsFile, streaksFile, historyFile, attemptsFile])
      name: await participant(name).readAsBytes(),
    for (final id in _ids) id: await note(id).readAsBytes(),
  };

  Future<void> close() async {
    await root.delete(recursive: true);
    await harness.delete(recursive: true);
  }
}

final class _Child {
  _Child(this.process, this.output, this.errors);
  final Process process;
  final StreamSubscription<String> output;
  final StreamSubscription<String> errors;
  Future<void> close() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await output.cancel();
    await errors.cancel();
  }
}

const _driver = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/mutation_guards.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/storage/training_intent.dart';
import 'package:chess_auto_prep/v2/storage/training_writes.dart';
Future<void> main(List<String> args) async {
  final documents = Directory(args[0]);
  final support = Directory(args[1]);
  final gate = RecoveryGate(documents: documents, support: support);
  if (args[4] == 'recover') {
    await gate.run(() async => stdout.writeln('recovered'));
    return;
  }
  final commands = jsonDecode(await File(args[3]).readAsString()) as List;
  final source = await probeDocument(args[2]) as FileFound;
  var queued = 0;
  var completed = 0;
  final engine = TrainingWrites(documents: documents, support: support,
    testHook: (step) async {
      if (step == TrainingWriteStep.queued) queued++;
      if (step == TrainingWriteStep.completed) completed++;
      if (step.name != args[4] ||
          (step == TrainingWriteStep.queued && queued != commands.length) ||
          (step == TrainingWriteStep.completed && completed != commands.length)) return;
      stdout.writeln('checkpoint durable');
      await stdout.flush();
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    });
  Future<void> guarded(Future<void> Function() action) => gate.run(
    () => lockedForRelocation(documents, DocumentRef(args[2]), [support],
      action, (detail) => throw StateError(detail)), recoverTraining: false);
  for (final command in commands) {
    await guarded(() => engine.enqueue(id: command['id'] as String,
      payload: command['payload'] as String,
      sources: {args[2]: source.revision},
      predecessorId: command['predecessor'] as String?));
  }
  final last = commands.last as Map;
  await guarded(() => engine.commit(id: last['id'] as String,
    digest: trainingDigest(last['payload'] as String)));
}
''';
