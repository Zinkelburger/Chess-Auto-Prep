import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _before = '[Event "Line"]\n[ChapterName "Before"]\n\n1. e4 *\n';
const _after = '[Event "Line"]\n[ChapterName "After"]\n\n1. e4 *\n';
const _books =
    '{"version":1,"active":"book","future":7,"books":[{"id":"book","name":"Book","repertoires":[],"chapters":[{"path":"Course.pgn","section":"Before"}]}]}';
const _training = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory profile;
  late Directory documents;
  late Directory support;
  late File document;
  late File books;
  late Directory harnessFolder;
  late File harness;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('compound-process-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    await Directory(p.join(documents.path, 'repertoires')).create();
    document = await File(
      p.join(documents.path, 'repertoires', 'Course.pgn'),
    ).writeAsString(_before);
    books = await File(
      p.join(support.path, 'books.json'),
    ).writeAsString(_books);
    for (final name in _training) {
      await File(
        p.join(documents.path, name),
      ).writeAsString('unchanged $name\n');
    }
    // Native assets resolve from the package; only this executable is in it.
    // All documents and metadata are a disposable synthetic profile.
    harnessFolder = await Directory(
      p.join(Directory.current.path, '.dart_tool'),
    ).createTemp('compound-process-');
    harness = await File(
      p.join(harnessFolder.path, 'interrupted_save.dart'),
    ).writeAsString(_harness);
  });
  tearDown(() async {
    await profile.delete(recursive: true);
    await harnessFolder.delete(recursive: true);
  });

  for (final checkpoint in ['prepared', 'document']) {
    test(
      'SIGKILL after $checkpoint: v1 refuses, v2 recovers compound once',
      () async {
        final child = await _start(harness, documents, support, checkpoint);
        addTearDown(child.close);
        final note =
            (await Directory(
                  p.join(support.path, 'compound-writes'),
                ).list().toList()).single
                as File;
        final interrupted = await note.readAsString();
        expect(
          jsonDecode(interrupted)['state'],
          checkpoint == 'prepared' ? 'prepared' : 'committing',
        );
        expect(
          await document.readAsString(),
          checkpoint == 'prepared' ? _before : _after,
        );
        expect(await books.readAsString(), _books);
        expect(child.process.kill(ProcessSignal.sigkill), isTrue);
        await child.process.exitCode.timeout(const Duration(seconds: 10));

        final old = IOStorageService(
          documentsRoot: documents,
          supportRoot: support,
        );
        await expectLater(
          old.readFile(document.path),
          throwsA(isA<RepertoireRecoveryRequired>()),
        );
        await expectLater(
          old.writeFile(document.path, 'must not land'),
          throwsA(isA<RepertoireRecoveryRequired>()),
        );
        expect(await note.readAsString(), interrupted);
        expect(
          await document.readAsString(),
          checkpoint == 'prepared' ? _before : _after,
        );
        expect(await books.readAsString(), _books);

        // Reopen through a configured root alias to cover domain and receipt
        // identity across a genuine process restart, not just object recreation.
        final alias = Directory(p.join(profile.path, 'Documents-alias'));
        await Link(alias.path).create(documents.path);
        final store = PgnFileStore(documents: alias, support: support);
        final ref = DocumentRef(
          p.join(alias.path, 'repertoires', 'Course.pgn'),
        );
        final opened = await store
            .open(ref)
            .timeout(const Duration(seconds: 10));
        expect(opened, isA<Opened>());
        expect(
          (opened as Opened).text,
          checkpoint == 'prepared' ? _before : _after,
        );
        final completed = await note.readAsString();
        expect(
          jsonDecode(completed)['state'],
          checkpoint == 'prepared' ? 'cancelled' : 'complete',
        );
        final recoveredBooks = await books.readAsString();
        expect(
          recoveredBooks,
          checkpoint == 'prepared'
              ? _books
              : _books.replaceFirst('"section":"Before"', '"section":"After"'),
        );
        expect(
          await old.readFile(document.path),
          checkpoint == 'prepared' ? _before : _after,
        );
        expect(await store.open(ref), isA<Opened>());
        expect(await note.readAsString(), completed);
        expect(await books.readAsString(), recoveredBooks);
        for (final name in _training) {
          expect(
            await File(p.join(documents.path, name)).readAsString(),
            'unchanged $name\n',
          );
        }
      },
      skip: !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

Future<_Child> _start(
  File harness,
  Directory documents,
  Directory support,
  String checkpoint,
) async {
  final process = await Process.start('dart', [
    'run',
    '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
    harness.path,
    documents.path,
    support.path,
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
      if (!ready.isCompleted)
        ready.completeError(StateError('Child exited $code: $diagnostics'));
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

const _harness = r'''
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final documents = Directory(args[0]);
  final store = PgnFileStore(
    documents: documents,
    support: Directory(args[1]),
    compoundHook: (step) async {
      if (step.name != args[2]) return;
      stdout.writeln('checkpoint durable');
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    },
  );
  final ref = DocumentRef(p.join(documents.path, 'repertoires', 'Course.pgn'));
  final opened = await store.open(ref) as Opened;
  final result = await store.save(
    ref,
    opened.text.replaceFirst('[ChapterName "Before"]', '[ChapterName "After"]'),
    expected: opened.revision,
    scope: GamesEdited(
      GamesWritten(rewritten: {0}),
      references: ReferenceChanges([
        SectionRename(path: ref.path, from: 'Before', to: 'After'),
      ]),
    ),
  );
  if (result is! Saved) throw StateError('Save failed before checkpoint: $result');
}
''';
