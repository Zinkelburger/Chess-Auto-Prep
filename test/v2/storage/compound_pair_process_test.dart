@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _firstBefore =
    '[Event "Move me"]\n\n1. e4 *\n\n[Event "Stay"]\n\n1. c4 *\n';
const _firstAfter = '[Event "Stay"]\n\n1. c4 *\n';
const _secondBefore = '[Event "Target"]\n\n1. d4 *\n';
const _secondAfter =
    '[Event "Target"]\n\n1. d4 *\n\n[Event "Move me"]\n\n1. e4 *\n';
const _training = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];

void main() {
  for (final checkpoint in ['document', 'secondaryDocument', 'completed']) {
    test(
      'SIGKILL after $checkpoint recovers only the two accepted PGNs',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'compound-pair-process-',
        );
        final harness = await Directory(
          p.join(Directory.current.path, '.dart_tool'),
        ).createTemp('compound-pair-process-');
        addTearDown(() async {
          await root.delete(recursive: true);
          await harness.delete(recursive: true);
        });
        final documents = await Directory(
          p.join(root.path, 'Documents'),
        ).create();
        final support = await Directory(p.join(root.path, 'Support')).create();
        final first = await File(
          p.join(documents.path, 'First.pgn'),
        ).writeAsString(_firstBefore);
        final second = await File(
          p.join(documents.path, 'Second.pgn'),
        ).writeAsString(_secondBefore);
        final books = await File(
          p.join(support.path, 'books.json'),
        ).writeAsString('{ "version":1, "books":[], "future":17 }\n');
        final bookBytes = await books.readAsBytes();
        for (final name in _training) {
          await File(
            p.join(documents.path, name),
          ).writeAsString('untouched $name\n');
        }
        final input = await File(p.join(root.path, 'command.json'))
            .writeAsString(
              jsonEncode({
                'first': first.path,
                'firstBefore': _firstBefore,
                'firstAfter': _firstAfter,
                'second': second.path,
                'secondBefore': _secondBefore,
                'secondAfter': _secondAfter,
              }),
            );
        final script = await File(
          p.join(harness.path, 'pair.dart'),
        ).writeAsString(_driver);
        List<String> args(String phase) => [
          'run',
          '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
          script.path,
          documents.path,
          support.path,
          input.path,
          phase,
        ];
        final child = await _start(args(checkpoint));
        addTearDown(child.close);
        final note = File(
          p.join(support.path, 'compound-writes', 'pair-process.json'),
        );
        // The record is removed as soon as both files are written.
        expect(await note.exists(), checkpoint != 'completed');
        expect(await first.readAsString(), _firstAfter);
        expect(
          await second.readAsString(),
          checkpoint == 'document' ? _secondBefore : _secondAfter,
        );
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        expect(
          await child.process.exitCode.timeout(const Duration(seconds: 10)),
          isNot(0),
        );
        for (var iteration = 0; iteration < 2; iteration++) {
          final result = await Process.run(
            'dart',
            args('recover'),
            workingDirectory: Directory.current.path,
          ).timeout(const Duration(seconds: 30));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout, contains('recovered'));
          expect(await first.readAsString(), _firstAfter);
          expect(await second.readAsString(), _secondAfter);
          expect(await books.readAsBytes(), bookBytes);
          for (final name in _training) {
            expect(
              await File(p.join(documents.path, name)).readAsString(),
              'untouched $name\n',
            );
          }
          expect(await note.exists(), isFalse);
          expect(
            Directory(p.join(support.path, 'recovery-quarantine')).existsSync(),
            isFalse,
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

Future<_Child> _start(List<String> args) async {
  final process = await Process.start(
    'dart',
    args,
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
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/mutation_guards.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
Future<void> main(List<String> args) async {
  final documents = Directory(args[0]);
  final support = Directory(args[1]);
  final gate = RecoveryGate(documents: documents, support: support);
  if (args[3] == 'recover') {
    await gate.run(() async => stdout.writeln('recovered'));
    return;
  }
  final input = jsonDecode(await File(args[2]).readAsString()) as Map;
  final command = CompoundCommit.pair(id: 'pair-process',
    primary: CompoundDocument(path: input['first'] as String,
      before: input['firstBefore'] as String, after: input['firstAfter'] as String),
    secondary: CompoundDocument(path: input['second'] as String,
      before: input['secondBefore'] as String, after: input['secondAfter'] as String));
  final engine = CompoundWrites(documents: documents, support: support,
    testHook: (step) async {
      if (step.name != args[3]) return;
      stdout.writeln('checkpoint durable');
      await stdout.flush();
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    });
  await gate.run(() => lockedForRelocation(documents, DocumentRef(command.documentPath),
    [support], () => engine.commit(command), (detail) => throw StateError(detail)));
}
''';
