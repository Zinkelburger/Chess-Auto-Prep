import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/legacy_profile.dart';

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

  // The old app took the same domain lock around every repertoire operation;
  // its holder here takes that lock directly, as it did.
  for (final holder in ['old app', 'v2']) {
    final folder = holder == 'v2' ? 'unfinished-moves' : 'repertoire-mutations';
    test(
      '$holder child domain excludes v2 through a canonical alias',
      () async {
        final child = await _hold(harness, holder, alias, support, false);
        addTearDown(child.close);
        var entered = false;
        final reading = RecoveryGate(documents: documents, support: support)
            .run(() async {
              entered = true;
            });
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
      'killing $holder releases the domain and v2 keeps working',
      () async {
        final child = await _hold(harness, holder, documents, support, true);
        addTearDown(child.close);
        final metadata = File(p.join(support.path, folder, '1-a.json'));
        expect(await metadata.readAsString(), 'interrupted-json');
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));
        // A damaged leftover is logged or set aside, never a reason to
        // refuse access; the old app's leftover is its owner's to finish.
        final reading = RecoveryGate(
          documents: alias,
          support: support,
        ).run(() async => 'read');
        expect(await reading.timeout(const Duration(seconds: 10)), 'read');
        if (holder == 'v2') {
          expect(await _quarantined(support), contains('interrupted-json'));
        } else {
          expect(await metadata.readAsString(), 'interrupted-json');
        }
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
      'killed $holder landed move leaves v2 working; v2 finishes only its own',
      () async {
        final from = p.join(documents.path, 'repertoires', 'Old', 'Main.pgn');
        final to = p.join(documents.path, 'repertoires', 'New', 'Main.pgn');
        if (holder == 'v2') {
          await Directory(p.dirname(from)).create();
          await File(from).writeAsString('1. e4 *');
        } else {
          // The folder already renamed and the receipt still pending, as a
          // kill after the rename left them.
          await restoreLegacyProfile(profile, 'move-landed-at-kill');
        }
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
        final notes = Directory(p.join(support.path, folder));
        final note =
            (await notes.list().where((entry) => entry is File).toList()).single
                as File;
        final recorded = await note.readAsString();
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));
        expect(await note.readAsString(), recorded);
        for (final entry in original.entries) {
          expect(
            await File(p.join(documents.path, entry.key)).readAsString(),
            entry.value,
          );
        }
        if (holder != 'v2') {
          // The old app's move is its owner's to finish: v2 reads on and
          // leaves the receipt and the progress it names untouched.
          final foreignRead = await TrainingStore(
            documents,
            support: support,
          ).read({to});
          expect(foreignRead, isA<ProgressLoaded>());
          expect(await note.readAsString(), recorded);
          for (final entry in original.entries) {
            expect(
              await File(p.join(documents.path, entry.key)).readAsString(),
              entry.value,
            );
          }
          return;
        }
        Future<void> recover() async {
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
        expect(await notes.list().toList(), isEmpty);
      },
      skip: !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

/// The contents of every file set aside under Support/recovery-quarantine.
Future<List<String>> _quarantined(Directory support) async {
  final folder = Directory(p.join(support.path, 'recovery-quarantine'));
  if (!await folder.exists()) return const [];
  return [
    await for (final entry in folder.list(recursive: true))
      if (entry is File) await entry.readAsString(),
  ];
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

// Real separate Dart VM process holding the domain: v2 through its gate, the
// old app through the same directory lock it took. The malformed retained
// note models a crash during metadata publication: neither may interpret it
// as no pending operation. No new recovery format is created.
const _harness = r'''
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:path/path.dart' as p;
import 'package:document_file_io/document_file_io.dart';

Future<void> main(List<String> args) async {
  final documents = Directory(args[1]);
  final support = Directory(args[2]);
  Future<void> hold() async {
    if (args[3] == 'true') {
      final folder = Directory(p.join(support.path,
          args[0] == 'v2' ? 'unfinished-moves' : 'repertoire-mutations'));
      await folder.create();
      await File(p.join(folder.path, '1-a.json')).writeAsString('interrupted-json', flush: true);
    }
    stdout.writeln('domain held');
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  }
  final from = p.join(documents.path, 'repertoires', 'Old');
  final to = p.join(documents.path, 'repertoires', 'New');
  if (args[0] != 'v2') {
    final root = Directory(p.join(documents.path, 'repertoires'));
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    await withDirectoryLock(
      Directory(p.join(canonical, '.cap-directory-domain')),
      hold,
    );
  } else {
    final gate = RecoveryGate(documents: documents, support: support);
    await gate.run(() async {
      if (args[3] == 'checkpoint') {
        final identity = (await observeDirectory(from)).identity!;
        // The note an older build wrote before its rename; this build only
        // finishes them.
        final note = File(p.join(support.path, 'unfinished-moves', '1-a.json'));
        await note.parent.create(recursive: true);
        await note.writeAsString(
            jsonEncode({'from': from, 'to': to, 'identity': identity, 'folder': true}),
            flush: true);
        await Directory(from).rename(to);
        await syncDirectory(p.dirname(from));
      }
      await hold();
    });
  }
}
''';
