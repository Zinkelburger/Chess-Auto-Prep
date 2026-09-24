import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory alias;
  late File harness;
  late Directory harnessFolder;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('recovery-domain-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    await Directory(p.join(documents.path, 'repertoires')).create();
    await File(
      p.join(documents.path, 'repertoire_reviews.csv'),
    ).writeAsString('unchanged');
    alias = Directory(p.join(profile.path, 'alias'));
    await Link(alias.path).create(documents.path);
    // Keep the executable inside the package so dart run resolves the same
    // generated native assets as the app; user data remains in the temp profile.
    harnessFolder = await Directory(
      p.join(Directory.current.path, '.dart_tool'),
    ).createTemp('recovery-domain-');
    harness = File(p.join(harnessFolder.path, 'hold_domain.dart'));
    await harness.writeAsString(_harness);
  });
  tearDown(() async {
    await profile.delete(recursive: true);
    await harnessFolder.delete(recursive: true);
  });

  for (final holder in ['v1', 'v2']) {
    test(
      '$holder child domain excludes the other app through a canonical alias',
      () async {
        final child = await _hold(harness, holder, alias, support, false);
        addTearDown(child.close);
        var entered = false;
        final reading = holder == 'v1'
            ? RecoveryGate(documents: documents, support: support).run(
                () async {
                  entered = true;
                },
              )
            : IOStorageService(
                documentsRoot: documents,
                supportRoot: support,
              ).guardDocumentOperation(
                p.join(documents.path, 'repertoire_reviews.csv'),
                () async {
                  entered = true;
                },
              );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          entered,
          isFalse,
          reason: 'the actual child process still owns the domain',
        );
        child.process.stdin.writeln('release');
        expect(
          await child.process.exitCode.timeout(const Duration(seconds: 10)),
          0,
        );
        await reading.timeout(const Duration(seconds: 10));
        expect(entered, isTrue);
      },
      skip: !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'killing $holder releases domain and the other app refuses retained recovery',
      () async {
        final child = await _hold(harness, holder, documents, support, true);
        addTearDown(child.close);
        final metadata = File(
          p.join(
            support.path,
            holder == 'v1' ? 'repertoire-mutations' : 'unfinished-moves',
            '1-a.json',
          ),
        );
        expect(await metadata.readAsString(), 'interrupted-json');
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));
        final Future<Object?> reading = holder == 'v1'
            ? RecoveryGate(
                documents: alias,
                support: support,
              ).run(() async => 'unsafe success')
            : IOStorageService(
                documentsRoot: alias,
                supportRoot: support,
              ).readRepertoireReviewsCsv();
        await expectLater(
          reading.timeout(const Duration(seconds: 10)),
          throwsA(
            holder == 'v1'
                ? isA<RecoveryRequired>()
                : isA<RepertoireRecoveryRequired>(),
          ),
        );
        expect(await metadata.readAsString(), 'interrupted-json');
        expect(
          await File(
            p.join(documents.path, 'repertoire_reviews.csv'),
          ).readAsString(),
          'unchanged',
        );
      },
      skip: !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 60)),
    );
    test(
      'killed $holder landed move is refused by the other app then recovered once',
      () async {
        final from = p.join(documents.path, 'repertoires', 'Old', 'Main.pgn');
        final to = p.join(documents.path, 'repertoires', 'New', 'Main.pgn');
        await Directory(p.dirname(from)).create();
        await File(from).writeAsString('1. e4 *');
        final original = _training(from);
        for (final entry in original.entries) {
          await File(
            p.join(documents.path, entry.key),
          ).writeAsString(entry.value);
        }
        final child = await _hold(
          harness,
          holder,
          documents,
          support,
          false,
          checkpoint: true,
        );
        addTearDown(child.close);
        expect(await File(from).exists(), isFalse);
        expect(await File(to).readAsString(), '1. e4 *');
        final notes = Directory(
          p.join(
            support.path,
            holder == 'v1' ? 'repertoire-mutations' : 'unfinished-moves',
          ),
        );
        final note =
            (await notes.list().where((entry) => entry is File).toList()).single
                as File;
        final recorded = await note.readAsString();
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));
        if (holder == 'v1') {
          final foreignRead = await TrainingStore(
            documents,
            support: support,
          ).read({to});
          expect(foreignRead, isA<ProgressFailed>());
        } else {
          await expectLater(
            IOStorageService(
              documentsRoot: documents,
              supportRoot: support,
            ).readRepertoireReviewsCsv(),
            throwsA(isA<RepertoireRecoveryRequired>()),
          );
        }
        expect(await note.readAsString(), recorded);
        for (final entry in original.entries) {
          expect(
            await File(p.join(documents.path, entry.key)).readAsString(),
            entry.value,
          );
        }
        Future<void> recover() async {
          if (holder == 'v1') {
            expect(
              await IOStorageService(
                documentsRoot: documents,
                supportRoot: support,
              ).readRepertoireReviewsCsv(),
              contains(to),
            );
          } else {
            final progress = await TrainingStore(
              documents,
              support: support,
            ).read({to});
            expect(progress, isA<ProgressLoaded>());
            final loaded = progress as ProgressLoaded;
            expect(loaded.reviews, hasLength(1));
            expect(loaded.streaks, hasLength(1));
            expect(loaded.mistakes, hasLength(1));
          }
        }

        await recover().timeout(const Duration(seconds: 10));
        final recovered = <String, String>{};
        for (final name in original.keys) {
          final text = await File(p.join(documents.path, name)).readAsString();
          expect(to.allMatches(text), hasLength(1), reason: name);
          expect(text, isNot(contains(from)), reason: name);
          recovered[name] = text;
        }
        await recover().timeout(const Duration(seconds: 10));
        for (final entry in recovered.entries) {
          expect(
            await File(p.join(documents.path, entry.key)).readAsString(),
            entry.value,
          );
        }
        if (holder == 'v2') {
          expect(await notes.list().toList(), isEmpty);
        } else {
          expect(jsonDecode(await note.readAsString())['state'], 'completed');
        }
      },
      skip: !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

Map<String, String> _training(String source) => {
  'repertoire_reviews.csv':
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\n'
      '$source,line,Opening,2.50,7,2027-01-01T00:00:00.000Z,good,,4,2,false\n',
  'repertoire_move_progress.csv':
      'repertoire_id,line_id,move_index,correct_streak,learned\n$source,line,2,5,1\n',
  'repertoire_review_history.csv':
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n'
      '$source,line,2026-09-16T00:00:00.000Z,good,0,drilling\n',
  'repertoire_move_attempts.jsonl':
      '${jsonEncode({'repertoireId': source, 'lineId': 'line', 'moveIndex': 2, 'fen': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1', 'playedSan': 'd4', 'expectedSan': 'e4', 'correct': false, 'phase': 'drilling', 'timestampUtc': '2026-09-16T00:00:00.000Z', 'futureField': 7})}\n',
};

Future<_Child> _hold(
  File harness,
  String implementation,
  Directory documents,
  Directory support,
  bool interrupted, {
  bool checkpoint = false,
}) async {
  final process = await Process.start('dart', [
    'run',
    '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
    harness.path,
    implementation,
    documents.path,
    support.path,
    checkpoint ? 'checkpoint' : '$interrupted',
  ], workingDirectory: Directory.current.path);
  final ready = Completer<void>();
  final diagnostics = StringBuffer();
  final output = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == 'domain held' && !ready.isCompleted) ready.complete();
        diagnostics.writeln(line);
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
    await ready.future.timeout(const Duration(seconds: 40));
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

// Real separate Dart VM process using each production guard. The malformed
// retained note models a crash during metadata publication: neither application
// may interpret it as no pending operation. No new recovery format is created.
const _harness = r'''
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:path/path.dart' as p;
import 'package:document_file_io/document_file_io.dart';

Future<void> main(List<String> args) async {
  final documents = Directory(args[1]);
  final support = Directory(args[2]);
  Future<void> hold() async {
    if (args[3] == 'true') {
      final folder = Directory(p.join(support.path,
          args[0] == 'v1' ? 'repertoire-mutations' : 'unfinished-moves'));
      await folder.create();
      await File(p.join(folder.path, '1-a.json')).writeAsString('interrupted-json', flush: true);
    }
    stdout.writeln('domain held');
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  }
  final from = p.join(documents.path, 'repertoires', 'Old');
  final to = p.join(documents.path, 'repertoires', 'New');
  if (args[0] == 'v1') {
    final moves = RepertoireDirectoryMutations(
      root: Directory(p.join(documents.path, 'repertoires')),
      journals: Directory(p.join(support.path, 'repertoire-mutations')),
      foreignRecoveryNotes: Directory(p.join(support.path, 'unfinished-moves')),
      repoint: (_, _, _) async {},
      testHook: (step) async {
        if (args[3] == 'checkpoint' && step == RepertoireMoveStep.moved) await hold();
      },
    );
    if (args[3] == 'checkpoint') {
      await moves.move(from, to);
    } else {
      await moves.guard(hold);
    }
  } else {
    final gate = RecoveryGate(documents: documents, support: support);
    await gate.run(() async {
      if (args[3] == 'checkpoint') {
        final identity = (await observeDirectory(from)).identity!;
        await gate.notes.record('1-a', from: from, to: to, identity: identity, folder: true);
        await Directory(from).rename(to);
        await syncDirectory(p.dirname(from));
      }
      await hold();
    });
  }
}
''';
