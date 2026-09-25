import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_probe.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/study_files.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

/// The store a new app session opens, which finishes what an earlier one left.
PgnFileStore restarted(StoreFixture fixture) =>
    PgnFileStore(documents: fixture.documents, support: fixture.support);

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('first document read recovers a landed move before returning', () async {
    final before = fixture.ref('repertoires/Opening/Old.pgn');
    final after = fixture.ref('repertoires/Opening/New.pgn');
    await fixture.put(before, oneGame('1. d4'));
    final identity = (await probeDocument(before.path) as FileFound).identity;
    final rows = File(
      p.join(fixture.documents.path, 'repertoire_move_progress.csv'),
    );
    await rows.writeAsString(
      'repertoire_id,line_id,move_index,correct_streak,learned\n${before.path},line_1,4,2,true\n',
    );
    await PendingRepoints(fixture.support, documents: fixture.documents).record(
      'landed',
      from: before.path,
      to: after.path,
      identity: identity,
      folder: false,
    );
    await File(before.path).rename(after.path);

    final store = restarted(fixture);
    expect(await store.open(after), isA<Opened>());
    expect(await rows.readAsString(), contains('${after.path},line_1'));
    expect(
      await PendingRepoints(
        fixture.support,
        documents: fixture.documents,
      ).read(),
      isEmpty,
    );
    final settled = await rows.readAsBytes();
    expect(await store.open(after), isA<Opened>());
    expect(await rows.readAsBytes(), settled);
  });

  test(
    'a document in a root alias takes the Documents lock only once',
    () async {
      final alias = Link(p.join(fixture.documents.path, 'alias'));
      await alias.create(fixture.documents.path);
      final result = await fixture.store
          .create(fixture.ref('alias/Main.pgn'), oneGame('1. d4'))
          .timeout(const Duration(seconds: 2));
      expect(result, isA<Created>());
      expect(
        await File(p.join(fixture.documents.path, 'Main.pgn')).exists(),
        isTrue,
      );
    },
    skip: Platform.isWindows,
  );

  test('a corrupt recovery note is set aside; read and create work', () async {
    final ref = fixture.ref('repertoires/Opening/Main.pgn');
    await fixture.put(ref, oneGame('1. d4'));
    final note = File(
      p.join(fixture.support.path, 'unfinished-moves', 'bad.json'),
    );
    await note.parent.create(recursive: true);
    await note.writeAsString('not-json');

    final store = restarted(fixture);
    expect(await store.open(ref), isA<Opened>());
    final other = fixture.ref('repertoires/Opening/Other.pgn');
    expect(await store.create(other, oneGame('1. e4')), isA<Created>());
    expect(await note.exists(), isFalse);
    expect(await _setAside(fixture), ['not-json']);
  });

  for (final firstAccess in ['training', 'chapters', 'studies', 'deleted']) {
    test(
      '$firstAccess first access settles all training files exactly once',
      () => _firstAccess(fixture, firstAccess),
    );
  }

  test('a corrupt note blocks no training, listing or import', () async {
    final flat = fixture.ref('repertoires/Flat.pgn');
    await fixture.put(flat, oneGame('1. d4'));
    final note = File(
      p.join(fixture.support.path, 'unfinished-moves', 'bad.json'),
    );
    await note.parent.create(recursive: true);
    await note.writeAsString('not-json');
    final training = TrainingStore(fixture.documents, support: fixture.support);
    expect(await training.read({flat.path}), isA<ProgressLoaded>());
    expect(await training.write(), isA<ProgressWritten>());
    final store = restarted(fixture);
    final chapters = ChapterDirectory(
      Directory(p.join(fixture.documents.path, 'repertoires')),
      recovery: store.recovery,
      documents: store,
    );
    expect(await chapters.list(), isA<Repertoires>());
    expect(await chapters.deleted(), isA<DeletedChapters>());
    expect(
      await StudyDirectory(
        Directory(p.join(fixture.documents.path, 'studies')),
        recovery: store.recovery,
      ).list(),
      isA<StudiesListed>(),
    );
    final external = File(p.join(fixture.root.path, 'Imported.pgn'));
    await external.writeAsString(oneGame('1. e4'));
    final imported = await NativePgnFileImport(
      documents: fixture.documents.path,
      into: p.join(fixture.documents.path, 'pgn_collections'),
      recovery: store.recovery,
    ).insideDocuments(external.path);
    expect(imported, isNot(isA<ImportFailed>()));
    expect(await _setAside(fixture), ['not-json']);
  });
}

Future<List<String>> _setAside(StoreFixture fixture) async => [
  await for (final entry in Directory(
    p.join(fixture.support.path, 'recovery-quarantine'),
  ).list(recursive: true))
    if (entry is File) await entry.readAsString(),
];

Future<void> _firstAccess(StoreFixture fixture, String firstAccess) async {
  final before = fixture.ref('repertoires/Opening/Old.pgn');
  final after = fixture.ref('repertoires/Opening/New.pgn');
  await fixture.put(before, oneGame('1. d4'));
  final identity = (await probeDocument(before.path) as FileFound).identity;
  final files = {
    'repertoire_reviews.csv':
        'repertoire_id,line_id,line_name,ease,interval_days,due_at,last_rating,last_reviewed_at,passes,fails,excluded\n${before.path},line_1,Main,2.5,1,,good,,1,0,false\n',
    'repertoire_move_progress.csv':
        'repertoire_id,line_id,move_index,correct_streak,learned\n${before.path},line_1,4,2,true\n',
    'repertoire_review_history.csv':
        'repertoire_id,line_id,reviewed_at,rating,mistake,kind\n${before.path},line_1,2026-09-24T00:00:00Z,good,false,trainer\n',
    'repertoire_move_attempts.jsonl':
        '{"repertoireId":"${before.path}","lineId":"line_1"}\n',
  };
  for (final entry in files.entries) {
    await File(
      p.join(fixture.documents.path, entry.key),
    ).writeAsString(entry.value);
  }
  final notes = PendingRepoints(fixture.support, documents: fixture.documents);
  await notes.record(
    'landed',
    from: before.path,
    to: after.path,
    identity: identity,
    folder: false,
  );
  await File(before.path).rename(after.path);
  final store = restarted(fixture);
  final chapters = ChapterDirectory(
    Directory(p.join(fixture.documents.path, 'repertoires')),
    recovery: store.recovery,
  );
  switch (firstAccess) {
    case 'training':
      final loaded = await TrainingStore(
        fixture.documents,
        support: fixture.support,
      ).read({after.path});
      expect(loaded, isA<ProgressLoaded>());
      expect((loaded as ProgressLoaded).reviews.keys.single.source, after.path);
    case 'chapters':
      expect(await chapters.list(), isA<Repertoires>());
    case 'studies':
      expect(
        await StudyDirectory(
          Directory(p.join(fixture.documents.path, 'studies')),
          recovery: store.recovery,
        ).list(),
        isA<StudiesListed>(),
      );
    case 'deleted':
      expect(await chapters.deleted(), isA<DeletedChapters>());
  }
  expect(await notes.read(), isEmpty);
  for (final entry in files.entries) {
    final file = File(p.join(fixture.documents.path, entry.key));
    expect(
      await file.readAsString(),
      entry.value.replaceAll(before.path, after.path),
    );
  }
  expect(await fixture.store.open(after), isA<Opened>());
  for (final entry in files.entries) {
    expect(
      await File(p.join(fixture.documents.path, entry.key)).readAsString(),
      entry.value.replaceAll(before.path, after.path),
    );
  }
}
