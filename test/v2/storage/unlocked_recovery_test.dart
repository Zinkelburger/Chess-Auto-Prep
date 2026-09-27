// What a stopped process or a damaged record leaves behind never locks the
// user out: every scenario here ends with opening, saving and training
// working, and whatever could not be understood kept under
// Support/recovery-quarantine rather than deleted.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

/// [json] cut off halfway, as a kill mid-write leaves it.
String _cutOff(String json) => json.substring(0, json.length ~/ 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StoreFixture fixture;
  late DocumentRef chapter;
  late Revision revision;

  setUp(() async {
    fixture = await StoreFixture.create();
    chapter = fixture.ref('repertoires/Opening/Main.pgn');
    revision = await fixture.put(chapter, oneGame('1. e4'));
  });
  tearDown(() => fixture.dispose());

  /// A new app session on the same profile.
  PgnFileStore restart() =>
      PgnFileStore(documents: fixture.documents, support: fixture.support);

  Future<File> leave(String folder, String name, String text) async {
    final file = File(p.join(fixture.support.path, folder, name));
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  Future<List<String>> setAside() async {
    final folder = Directory(
      p.join(fixture.support.path, 'recovery-quarantine'),
    );
    if (!await folder.exists()) return const [];
    return [
      await for (final entry in folder.list(recursive: true))
        if (entry is File) p.basename(entry.path),
    ];
  }

  Future<void> openSaveRename(PgnFileStore store) async {
    final opened = await store.open(chapter) as Opened;
    final saved = await store.save(
      chapter,
      oneGame('1. d4'),
      expected: opened.revision,
      scope: const WholeDocument(),
    );
    expect(saved, isA<Saved>());
    final moved = await store.rename(
      chapter,
      'Renamed.pgn',
      expected: await fixture.revisionOf(chapter),
    );
    expect(moved, isA<Moved>());
    final renamed = fixture.ref('repertoires/Opening/Renamed.pgn');
    expect(await File(renamed.path).readAsString(), oneGame('1. d4'));
  }

  test('a half-written journal copy does not stop open or save', () async {
    final stage = await leave(
      'compound-writes',
      '.1-abc.json.v2-tmp',
      _cutOff('{"version": 1, "id": "1-abc", "state": "committing"}'),
    );
    final store = restart();
    expect(await store.open(chapter), isA<Opened>());
    expect(
      await store.save(
        chapter,
        oneGame('1. c4'),
        expected: revision,
        scope: const WholeDocument(),
      ),
      isA<Saved>(),
    );
    expect(await stage.exists(), isFalse);
  });

  for (final folder in ['compound-writes', 'relocation-writes']) {
    test('a damaged record in $folder is set aside; work goes on', () async {
      final record = await leave(folder, 'broken.json', 'not json at all');
      await openSaveRename(restart());
      expect(await record.exists(), isFalse);
      expect(await setAside(), contains('$folder-broken.json'));
    });
  }

  group('training', () {
    late String source;
    late LineKey key;

    setUp(() async {
      source = chapter.path;
      key = (source: source, id: 'line');
    });

    Review review(int passes) =>
        Review(key: key, lineName: 'Line', lastRating: 'good', passes: passes);
    Attempt answer(String played) => Attempt(
      key: key,
      ply: 0,
      fen: Fen.initial,
      played: played,
      expected: 'e4',
      correct: false,
      phase: AttemptPhase.drilling,
      at: DateTime.utc(2026, 9, 25),
    );
    File file(String name) => File(p.join(fixture.documents.path, name));
    TrainingStore training() =>
        TrainingStore(fixture.documents, support: fixture.support);

    test('an old training queue does not block reading or writing', () async {
      await leave('training-writes', 'done.json', '{"state":"complete"}');
      await leave('training-writes', 'queued.json', '{"state":"queued"}');
      final store = training();
      final loaded = await store.read({source}) as ProgressLoaded;
      expect(
        await store.write(
          reviews: [(before: null, after: review(1))],
          operation: ProgressOperation(sources: loaded.sources),
        ),
        isA<ProgressWritten>(),
      );
      expect(await file(reviewsFile).readAsString(), contains(source));
      expect(
        await Directory(
          p.join(fixture.support.path, 'training-writes'),
        ).exists(),
        isFalse,
      );
      expect(await setAside(), ['training-writes-queued.json']);
    });

    test(
      'an autosave between accepting and writing keeps the answer',
      () async {
        final store = training();
        final loaded = await store.read({source}) as ProgressLoaded;
        final operation = ProgressOperation(sources: loaded.sources);
        expect(
          await store.enqueueAttempt(answer('d4'), operation: operation),
          isA<ProgressEnqueued>(),
        );
        // The document saver publishes the chapter atomically, as it does.
        await replaceFile(source, utf8.encode(oneGame('1. e4 e5')));
        expect(await store.commit(operation), isA<ProgressWritten>());
        final lines = await file(attemptsFile).readAsLines();
        expect(lines.single, contains('"playedSan":"d4"'));
      },
    );

    test('a change whose chapter is gone does not hold up the next', () async {
      final store = training();
      final loaded = await store.read({source}) as ProgressLoaded;
      final first = ProgressOperation(sources: loaded.sources);
      expect(
        await store.enqueueAttempt(answer('d4'), operation: first),
        isA<ProgressEnqueued>(),
      );
      final text = await File(source).readAsString();
      await File(source).delete();
      expect(await store.commit(first), isA<ProgressConflict>());
      await File(source).writeAsString(text);
      final again = await store.read({source}) as ProgressLoaded;
      expect(
        await store.logAttempt(
          answer('c4'),
          operation: ProgressOperation(sources: again.sources),
        ),
        isA<ProgressWritten>(),
      );
      final lines = await file(attemptsFile).readAsLines();
      expect(lines.single, contains('"playedSan":"c4"'));
    });

    test(
      'a lost write acknowledgement never appends an answer twice',
      () async {
        var failures = 1;
        final store = TrainingStore(
          fixture.documents,
          support: fixture.support,
          publish: (path, bytes) async {
            await replaceFile(path, bytes);
            if (failures-- > 0) {
              throw const FileSystemException('acknowledgement lost');
            }
          },
        );
        final loaded = await store.read({source}) as ProgressLoaded;
        final operation = ProgressOperation(sources: loaded.sources);
        expect(
          await store.logAttempt(answer('d4'), operation: operation),
          isA<ProgressFailed>(),
        );
        expect(
          await store.logAttempt(answer('d4'), operation: operation),
          isA<ProgressWritten>(),
        );
        expect(await file(attemptsFile).readAsLines(), hasLength(1));
      },
    );
  });

  test('the old app reads a PGN while a v2 edit is unfinished', () async {
    await leave(
      'compound-writes',
      'pending.json',
      '{"version":1,"id":"pending","state":"committing"}',
    );
    final io = IOStorageService(
      documentsRoot: fixture.documents,
      supportRoot: fixture.support,
    );
    expect(await io.readFile(chapter.path), oneGame('1. e4'));
  });
}
