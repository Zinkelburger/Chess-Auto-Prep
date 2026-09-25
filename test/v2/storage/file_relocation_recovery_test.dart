import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart' as training;
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  late DocumentRef from;
  late DocumentRef to;
  late Revision revision;
  late Map<String, String?> before;
  late training.TrainingRepointPlan plan;
  late String booksBefore;
  const id = 'file-move-1';
  final documentText = oneGame('1. e4');

  File participant(String name) => File(p.join(fixture.documents.path, name));
  File books() => File(p.join(fixture.support.path, 'books.json'));
  File note() =>
      File(p.join(fixture.support.path, 'relocation-writes', '$id.json'));
  FileRelocations engine({FileRelocationStep? interrupt}) => FileRelocations(
    documents: fixture.documents,
    support: fixture.support,
    testHook: interrupt == null
        ? null
        : (step) async {
            if (step == interrupt)
              throw StateError('interrupted at ${step.name}');
          },
  );
  Future<MoveResult> move(FileRelocations owner) =>
      owner.move(from, to, expected: revision, operationId: id);

  setUp(() async {
    fixture = await StoreFixture.create();
    from = fixture.ref('repertoires/Course/Before.pgn');
    to = fixture.ref('repertoires/Course/After.pgn');
    revision = await fixture.put(from, documentText);
    before = {
      reviewsFile:
          '\ufeffrepertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\r\n'
          '${from.path},line,Mainline,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false\r\n',
      streaksFile:
          'repertoire_id,line_id,move_index,correct_streak,learned\n${from.path},line,1,2,true\n',
      historyFile:
          'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n${from.path},line,2026-08-31T00:00:00Z,good,false,trainer\n',
      attemptsFile:
          '${_attemptWithUnknownFields(from.path)}\n'
          '{ "repertoireId": "/unrelated.pgn", "unknown": 17 }\n',
    };
    for (final entry in before.entries) {
      await participant(entry.key).writeAsString(entry.value!);
    }
    plan = await training.TrainingRecords(fixture.documents).plan(from, to);
    booksBefore = _bookSnapshot();
    await books().writeAsString(booksBefore);
  });
  tearDown(() => fixture.dispose());

  Future<void> expectState({required bool moved}) async {
    expect(await File(from.path).exists(), !moved);
    expect(await File(to.path).exists(), moved);
    expect(
      await File(moved ? to.path : from.path).readAsString(),
      documentText,
    );
    for (final file in plan.files) {
      expect(
        await participant(file.name).readAsBytes(),
        utf8.encode((moved ? file.after : file.before)!),
      );
    }
    expect(
      await books().readAsString(),
      moved
          ? booksBefore.replaceFirst('Course/Before.pgn', 'Course/After.pgn')
          : booksBefore,
    );
  }

  for (final step in FileRelocationStep.values) {
    test(
      'interruption at ${step.name} recovers twice and acknowledges exact retry',
      () async {
        expect(await move(engine(interrupt: step)), isA<IoFailure>());
        final preparedOnly = step == FileRelocationStep.prepared;
        await engine().recover();
        await expectState(moved: !preparedOnly);
        final settled = await note().readAsBytes();
        expect(
          jsonDecode(utf8.decode(settled))['state'],
          preparedOnly ? 'cancelled' : 'complete',
        );
        await engine().recover();
        expect(await note().readAsBytes(), settled);
        expect(await move(engine()), isA<Moved>());
        await expectState(moved: true);
        final complete = await note().readAsBytes();
        expect(await move(engine()), isA<Moved>());
        expect(await note().readAsBytes(), complete);
        for (final file in plan.files) {
          final backup = File(
            p.join(
              fixture.documents.path,
              '.cap-reference-history',
              id,
              file.name,
            ),
          );
          expect(await backup.readAsBytes(), utf8.encode(file.before!));
        }
      },
      skip: !Platform.isLinux,
    );
  }

  for (final original in [null, '', ' \r\n']) {
    test(
      'intent refuses external change to ${original == null ? 'absent' : 'unchanged'} participant before PGN movement',
      () async {
        if (original == null) {
          await participant(attemptsFile).delete();
        } else {
          await participant(attemptsFile).writeAsString(original);
        }
        expect(
          await move(engine(interrupt: FileRelocationStep.intent)),
          isA<IoFailure>(),
        );
        final metadata = await note().readAsBytes();
        const foreign = '{"repertoireId":"/foreign.pgn","keep":true}\n';
        await participant(attemptsFile).writeAsString(foreign);
        for (var restart = 0; restart < 2; restart++) {
          await expectLater(
            engine().recover(),
            throwsA(isA<RecoveryRequired>()),
          );
          expect(await File(from.path).readAsString(), documentText);
          expect(await File(to.path).exists(), isFalse);
          expect(
            await participant(reviewsFile).readAsBytes(),
            utf8.encode(before[reviewsFile]!),
          );
          expect(await participant(attemptsFile).readAsString(), foreign);
          expect(await books().readAsString(), booksBefore);
          expect(await note().readAsBytes(), metadata);
        }
      },
      skip: !Platform.isLinux,
    );
  }

  for (final field in ['after', 'rowsChanged', 'extra']) {
    test(
      'altered $field journal is rejected before pending namespace move',
      () async {
        expect(
          await move(engine(interrupt: FileRelocationStep.intent)),
          isA<IoFailure>(),
        );
        final metadata =
            jsonDecode(await note().readAsString()) as Map<String, Object?>;
        switch (field) {
          case 'after':
            final files = metadata['training']! as List<Object?>;
            (files.first! as Map<String, Object?>)['after'] = 'forged';
          case 'rowsChanged':
            metadata['rowsChanged'] = 500;
          case 'extra':
            metadata['future'] = true;
        }
        final altered = jsonEncode(metadata);
        await note().writeAsString(altered);
        await expectLater(engine().recover(), throwsA(isA<RecoveryRequired>()));
        await expectState(moved: false);
        expect(await note().readAsString(), altered);
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'identical replacement source cannot inherit pending move authority',
    () async {
      expect(
        await move(engine(interrupt: FileRelocationStep.intent)),
        isA<IoFailure>(),
      );
      final metadata = await note().readAsBytes();
      await File(from.path).rename('${from.path}.original');
      await File(from.path).writeAsString(documentText);
      await expectLater(engine().recover(), throwsA(isA<RecoveryRequired>()));
      await expectState(moved: false);
      expect(await File('${from.path}.original').readAsString(), documentText);
      expect(await note().readAsBytes(), metadata);
    },
    skip: !Platform.isLinux,
  );

  test(
    'pending captured alias retarget refuses even through canonical roots',
    () async {
      final alias = Link(p.join(fixture.root.path, 'Documents-alias'));
      await alias.create(fixture.documents.path);
      final aliasFrom = DocumentRef(
        p.join(alias.path, p.relative(from.path, from: fixture.documents.path)),
      );
      final aliasTo = DocumentRef(
        p.join(alias.path, p.relative(to.path, from: fixture.documents.path)),
      );
      final owner = FileRelocations(
        documents: Directory(alias.path),
        support: fixture.support,
        testHook: (step) async {
          if (step == FileRelocationStep.intent)
            throw StateError('interrupted');
        },
      );
      expect(
        await owner.move(
          aliasFrom,
          aliasTo,
          expected: revision,
          operationId: id,
        ),
        isA<IoFailure>(),
      );
      final metadata = await note().readAsBytes();
      final foreign = await Directory(
        p.join(fixture.root.path, 'Foreign'),
      ).create();
      await alias.delete();
      await alias.create(foreign.path);
      await expectLater(engine().recover(), throwsA(isA<RecoveryRequired>()));
      await expectState(moved: false);
      expect(await note().readAsBytes(), metadata);
      expect(await foreign.list().toList(), isEmpty);
      await alias.delete();
      await alias.create(fixture.documents.path);
      await engine().recover();
      await expectState(moved: true);
      expect(await move(engine()), isA<Moved>());
    },
    skip: !Platform.isLinux,
  );

  for (final checkpoint in ['document', 'reviews']) {
    test(
      'SIGKILL after $checkpoint resumes the retained complete operation',
      () async {
        final folder = await Directory(
          p.join(Directory.current.path, '.dart_tool'),
        ).createTemp('file-relocation-process-');
        addTearDown(() => folder.delete(recursive: true));
        final harness = await File(
          p.join(folder.path, 'relocate.dart'),
        ).writeAsString(_processDriver);
        final child = await _startChild(harness, fixture, from, to, checkpoint);
        addTearDown(child.close);
        expect(await File(from.path).exists(), isFalse);
        expect(await File(to.path).readAsString(), documentText);
        expect(jsonDecode(await note().readAsString())['state'], 'committing');
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));
        await engine().recover();
        await expectState(moved: true);
        final completed = await note().readAsBytes();
        await engine().recover();
        expect(await move(engine()), isA<Moved>());
        expect(await note().readAsBytes(), completed);
        await expectState(moved: true);
      },
      skip: !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  test(
    'completed retry does not overwrite later edits or reused source',
    () async {
      expect(await move(engine()), isA<Moved>());
      final metadata = await note().readAsBytes();
      await File(from.path).writeAsString(documentText);
      await File(to.path).writeAsString(oneGame('1. d4'));
      await participant(historyFile).writeAsString('later history');
      await books().writeAsString('{"later":true}');
      await engine().recover();
      expect(await move(engine()), isA<Moved>());
      expect(await File(from.path).readAsString(), documentText);
      expect(await File(to.path).readAsString(), oneGame('1. d4'));
      expect(await participant(historyFile).readAsString(), 'later history');
      expect(await books().readAsString(), '{"later":true}');
      expect(await note().readAsBytes(), metadata);
    },
    skip: !Platform.isLinux,
  );
}

String _attemptWithUnknownFields(String path) => jsonEncode({
  'repertoireId': path,
  'future': {
    'preserve': [1, 'two'],
  },
});

String _bookSnapshot() => jsonEncode({
  'version': 1,
  'future': {'preserve': true},
  'books': [
    {
      'id': 'book',
      'name': 'Book',
      'repertoires': <String>[],
      'chapters': [
        {'path': 'Course/Before.pgn', 'section': null, 'annotation': 7},
      ],
    },
  ],
});

Future<_Child> _startChild(
  File harness,
  StoreFixture fixture,
  DocumentRef from,
  DocumentRef to,
  String checkpoint,
) async {
  final process = await Process.start('dart', [
    'run',
    '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
    harness.path,
    fixture.documents.path,
    fixture.support.path,
    from.path,
    to.path,
    checkpoint,
  ], workingDirectory: Directory.current.path);
  final ready = Completer<void>();
  final diagnostics = StringBuffer();
  final output = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == 'checkpoint durable' && !ready.isCompleted)
          ready.complete();
        diagnostics.writeln(line);
      });
  final errors = process.stderr
      .transform(utf8.decoder)
      .listen(diagnostics.write);
  unawaited(
    process.exitCode.then((code) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Child exited $code: $diagnostics'));
      }
    }),
  );
  final child = _Child(process, output, errors);
  try {
    await ready.future.timeout(const Duration(seconds: 60));
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

const _processDriver = r'''
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';

Future<void> main(List<String> args) async {
  final from = DocumentRef(args[2]);
  final observed = await probeDocument(from.path) as FileFound;
  final owner = FileRelocations(
    documents: Directory(args[0]),
    support: Directory(args[1]),
    testHook: (step) async {
      if (step.name != args[4]) return;
      stdout.writeln('checkpoint durable');
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    },
  );
  final result = await owner.move(from, DocumentRef(args[3]),
      expected: observed.revision, operationId: 'file-move-1');
  if (result is! Moved) throw StateError('Move failed before checkpoint: $result');
}
''';
