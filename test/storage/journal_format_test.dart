// Every kind of journal record the app writes, or once wrote, kept as bytes
// under fixtures/journal. A record written today must be exactly what
// today's encoder writes, every record must still decode, and a record of a
// version this build does not know is set aside, never obeyed. Paths in the
// fixtures are spelt under /profile.
//
// UPDATE_JOURNAL_FORMAT=1 records the fixtures again from today's encoders,
// but never over a fixture of another version: that one stays frozen, so
// what older builds left on disk is still proved to recover.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/storage/compound_commit.dart';
import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/operation_journal.dart';
import 'package:chess_auto_prep/storage/recovery_files.dart';
import 'package:chess_auto_prep/storage/recovery_ledger.dart';
import 'package:chess_auto_prep/storage/relocation_notes.dart';
import 'package:chess_auto_prep/storage/relocation_record.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/training_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

final _update = Platform.environment['UPDATE_JOURNAL_FORMAT'] == '1';
const _placeholder = '/profile';
const _posixOnly = 'the fixtures spell POSIX paths';

File _fixture(String name) =>
    File(p.join('test', 'storage', 'fixtures', 'journal', '$name.json'));

/// [path] as it appears inside a JSON string.
String _inJson(String path) {
  final quoted = jsonEncode(path);
  return quoted.substring(1, quoted.length - 1);
}

/// [bytes] a record holds, with [root] spelt as the placeholder.
String _placeheld(List<int> bytes, String root) =>
    utf8.decode(bytes).replaceAll(_inJson(root), _placeholder);

/// A fixture with the placeholder spelt as [root] again.
Future<String> _rooted(String name, String root) async => (await _fixture(
  name,
).readAsString()).replaceAll(_placeholder, _inJson(root));

/// Checks [text], as today's encoder wrote it, against the fixture [name];
/// under UPDATE_JOURNAL_FORMAT=1 writes it there instead, unless the fixture
/// holds another version.
Future<void> _expectFixture(String name, String text) async {
  final file = _fixture(name);
  if (_update) {
    if (await file.exists()) {
      final kept = (jsonDecode(await file.readAsString()) as Map)['version'];
      final written = (jsonDecode(text) as Map)['version'];
      if (kept != written) {
        fail(
          'Today\'s encoder writes $name as version $written, but the fixture '
          'holds version $kept. Keep that fixture as it is, so its records '
          'still recover, and add one for version $written.',
        );
      }
    }
    await file.create(recursive: true);
    await file.writeAsString(text);
    return;
  }
  expect(
    text,
    await file.readAsString(),
    reason:
        'The $name record changed shape. Old records must still decode; '
        'record the new shape with UPDATE_JOURNAL_FORMAT=1 only on purpose.',
  );
}

const _a =
    '[Event "Line 1"]\n[ChapterName "Before"]\n[Result "*"]\n\n1. d4 *\n';
const _aRenamed =
    '[Event "Line 1"]\n[ChapterName "After"]\n[Result "*"]\n\n1. d4 *\n';
const _b = '[Event "Line 2"]\n[Result "*"]\n\n1. e4 *\n';
const _moved = '[Event "Line 3"]\n[Result "*"]\n\n1. c4 *\n';

String _books(String section) => jsonEncode({
  'version': 1,
  'books': [
    {
      'id': 'book',
      'name': 'Book',
      'repertoires': <String>[],
      'chapters': [
        {'path': 'KID/A.pgn', 'section': section},
      ],
    },
  ],
  'unknown': 'kept',
});

String _review(String path) =>
    '$path,line,Main,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false\n';

/// The compound records: a section rename (version 1), a line move between
/// two chapters (version 2) and one carrying its training rows (version 3).
Map<String, CompoundCommit> _compounds(String documents) {
  final a = p.join(documents, 'repertoires', 'KID', 'A.pgn');
  final b = p.join(documents, 'repertoires', 'KID', 'B.pgn');
  final primary = CompoundDocument(path: a, before: '$_a\n$_moved', after: _a);
  final secondary = CompoundDocument(
    path: b,
    before: _b,
    after: '$_b\n$_moved',
  );
  return {
    'compound_v1_section_rename': CompoundCommit(
      id: 'rename-1',
      documentPath: a,
      documentBefore: _a,
      documentAfter: _aRenamed,
      booksBefore: _books('Before'),
      booksAfter: _books('After'),
    ),
    'compound_v2_pair': CompoundCommit.pair(
      id: 'pair-2',
      primary: primary,
      secondary: secondary,
    ),
    'compound_v3_pair_training': CompoundCommit.pair(
      id: 'pair-3',
      primary: primary,
      secondary: secondary,
      training: [
        CompoundTraining(
          name: reviewsFile,
          before: '$reviewsHeader\n${_review(a)}',
          after: '$reviewsHeader\n${_review(b)}',
        ),
        CompoundTraining(
          name: streaksFile,
          before: '$streaksHeader\n$a,line,1,2,true\n',
          after: '$streaksHeader\n$b,line,1,2,true\n',
        ),
        const CompoundTraining(name: historyFile, before: null, after: null),
        CompoundTraining(
          name: attemptsFile,
          before: null,
          after: '${jsonEncode({'repertoireId': b, 'lineId': 'line'})}\n',
        ),
      ],
    ),
  };
}

/// Puts every participant of [command] as it was before, or after, it.
Future<void> _put(
  CompoundCommit command,
  StoreFixture fixture, {
  required bool after,
}) async {
  Future<void> write(String path, String? text) async {
    final file = File(path);
    if (text == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  for (final document in command.documents) {
    await write(document.path, after ? document.after : document.before);
  }
  for (final file in command.training) {
    await write(
      p.join(fixture.documents.path, file.name),
      after ? file.after : file.before,
    );
  }
  if (command.secondary == null) {
    await write(
      p.join(fixture.support.path, 'books.json'),
      after ? command.booksAfter : command.booksBefore,
    );
  }
}

Future<Map<String, String?>> _participants(
  CompoundCommit command,
  StoreFixture fixture,
) async {
  Future<String?> read(String path) async =>
      await File(path).exists() ? await File(path).readAsString() : null;
  return {
    for (final document in command.documents)
      document.path: await read(document.path),
    for (final file in command.training)
      file.name: await read(p.join(fixture.documents.path, file.name)),
    if (command.secondary == null)
      'books.json': await read(p.join(fixture.support.path, 'books.json')),
  };
}

Map<String, String?> _expected(CompoundCommit command, {required bool after}) =>
    {
      for (final document in command.documents)
        document.path: after ? document.after : document.before,
      for (final file in command.training)
        file.name: after ? file.after : file.before,
      if (command.secondary == null)
        'books.json': after ? command.booksAfter : command.booksBefore,
    };

void main() {
  late StoreFixture fixture;
  late String root;

  setUp(() async {
    fixture = await StoreFixture.create();
    root = fixture.root.resolveSymbolicLinksSync();
  });
  tearDown(() => fixture.dispose());

  String documents() => p.join(root, 'Documents');
  CompoundWrites compounds({CompoundWriteStep? stop}) => CompoundWrites(
    documents: fixture.documents,
    support: fixture.support,
    testHook: stopOnceAt(stop?.name),
  );
  File record(String folder, String id) =>
      File(p.join(fixture.support.path, folder, '$id.json'));

  for (final name in _compounds(_placeholder).keys) {
    group(name, () {
      CompoundCommit command() => _compounds(documents())[name]!;

      test('is what a commit writes down today', () async {
        await _put(command(), fixture, after: false);
        expect(
          await compounds(stop: CompoundWriteStep.intent).commit(command()),
          isA<Deferred>(),
        );
        final bytes = await record(
          'compound-writes',
          command().id,
        ).readAsBytes();
        await _expectFixture(name, _placeheld(bytes, root));
        expect(
          RecoveryLedger.of(
            fixture.support,
          ).owing(CompoundWrites.journal, command().id)!.paths,
          containsAll(command().documents.map((d) => d.path)),
        );
      });

      test('is finished by the next recovery', () async {
        await _put(command(), fixture, after: false);
        final file = record('compound-writes', command().id);
        await file.parent.create(recursive: true);
        await file.writeAsString(await _rooted(name, root));
        await compounds().recover();
        expect(RecoveryLedger.of(fixture.support).owed, isEmpty);
        expect(
          await _participants(command(), fixture),
          _expected(command(), after: true),
        );
        expect(await file.exists(), isFalse);
        expect(fixture.quarantined(), isEmpty);
      });

      test('of an unknown version is set aside, not obeyed', () async {
        await _put(command(), fixture, after: false);
        final json = jsonDecode(await _rooted(name, root)) as Map;
        final file = record('compound-writes', command().id);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode({...json, 'version': 99}));
        await compounds().recover();
        expect(RecoveryLedger.of(fixture.support).owed, isEmpty);
        expect(
          await _participants(command(), fixture),
          _expected(command(), after: false),
        );
        expect(fixture.quarantined(), hasLength(1));
      });
    }, skip: Platform.isWindows ? _posixOnly : false);
  }

  _relocations(() => fixture, () => root);
  _notes(() => fixture, () => root);
  _tournaments(() => fixture);
  _trainingQueue(() => fixture);

  test('every fixture is plain JSON as jsonEncode writes it', () async {
    final folder = _fixture('x').parent;
    for (final file in folder.listSync().whereType<File>()) {
      final text = await file.readAsString();
      expect(jsonEncode(jsonDecode(text)), text, reason: file.path);
    }
  });
}

/// File, delete and folder relocation records, recorded from real moves
/// stopped once their record is written. Native file identities are spelt
/// as placeholders, so the same move records the same bytes on any machine.
void _relocations(StoreFixture Function() fixture, String Function() root) {
  const records = {
    'relocation_v1_move': 'move-1',
    'relocation_v1_delete': '1-abc',
    'relocation_v2_folder': 'folder-1',
  };
  Directory under(String name) => Directory(p.join(_placeholder, name));

  for (final MapEntry(key: name, value: id) in records.entries) {
    group(name, () {
      test('is what a move writes down today', () async {
        await _recordRelocation(fixture(), root(), name, id);
      });

      test('is finished by the next recovery', () async {
        final (record, target) = await _stopRelocation(fixture(), name, id);
        final real = utf8.decode(await record.readAsBytes());
        final text = _withIdentities(await _rooted(name, root()), real);
        await record.writeAsString(text);
        await FileRelocations(
          documents: fixture().documents,
          support: fixture().support,
        ).recover();
        expect(await record.exists(), isFalse);
        expect(fixture().quarantined(), isEmpty);
        expect(RecoveryLedger.of(fixture().support).owed, isEmpty);
        expect(
          await FileSystemEntity.type(target, followLinks: false),
          isNot(FileSystemEntityType.notFound),
        );
        final chapter = name == 'relocation_v2_folder'
            ? DocumentRef(p.join(target, 'A.pgn'))
            : DocumentRef(target);
        await fixture().expectTrained(chapter);
      });

      test('decodes and encodes again to the same bytes', () async {
        final text = await _fixture(name).readAsString();
        final record = RelocationRecord.fromJson(
          jsonDecode(text),
          id: id,
          documents: under('Documents'),
        );
        record.validate(
          documents: under('Documents'),
          support: under('Support'),
        );
        expect(utf8.decode(encodeJournal(record.toJson(record.state))), text);
      });

      test('of an unknown version is refused', () async {
        final json = jsonDecode(await _fixture(name).readAsString()) as Map;
        expect(
          () => RelocationRecord.fromJson(
            {...json, 'version': 99},
            id: id,
            documents: under('Documents'),
          ),
          throwsA(isA<RecoveryRequired>()),
        );
      });
    }, skip: Platform.isWindows ? _posixOnly : false);
  }
}

final _identity = RegExp(r'"identity":"([^"]*)"');

/// [fixture] with its placeholder identities spelt as the ones [real], a
/// record of the same move on this disk, names in the same order.
String _withIdentities(String fixture, String real) {
  final identities = <String>{
    for (final match in _identity.allMatches(real)) match[1]!,
  }.toList();
  return fixture.replaceAllMapped(_identity, (match) {
    final n = int.parse(match[1]!.split(':').last);
    return '"identity":"${identities[n - 1]}"';
  });
}

/// Runs the move [name] names on a trained chapter, stopping once its
/// record is written; answers the record and where the move goes.
Future<(File, String)> _stopRelocation(
  StoreFixture fixture,
  String name,
  String id,
) async {
  final chapter = fixture.ref('repertoires/KID/A.pgn');
  final revision = await fixture.put(chapter, _a);
  await fixture.train(chapter);
  final moves = FileRelocations(
    documents: fixture.documents,
    support: fixture.support,
    testHook: stopOnceAt(FileRelocationStep.intent.name),
  );
  final String target;
  switch (name) {
    case 'relocation_v1_move':
      target = fixture.ref('repertoires/KID/C.pgn').path;
      await moves.move(
        chapter,
        DocumentRef(target),
        expected: revision,
        operationId: id,
      );
    case 'relocation_v1_delete':
      target = p.join(p.dirname(chapter.path), '.cap-pgn-history', '$id-A.pgn');
      await moves.delete(chapter, expected: revision, operationId: id);
    default:
      target = p.join(fixture.documents.path, 'repertoires', 'KID2');
      await moves.moveFolder(p.dirname(chapter.path), target, operationId: id);
  }
  final record = File(
    p.join(fixture.support.path, 'relocation-writes', '$id.json'),
  );
  return (record, target);
}

/// Runs the move [name] names on a trained chapter, stopping once its
/// record is written, and keeps that record as the fixture.
Future<void> _recordRelocation(
  StoreFixture fixture,
  String root,
  String name,
  String id,
) async {
  final (record, _) = await _stopRelocation(fixture, name, id);
  final bytes = await record.readAsBytes();
  final identities = <String, String>{};
  final text = _placeheld(bytes, root).replaceAllMapped(_identity, (match) {
    final placeholder = identities.putIfAbsent(
      match[1]!,
      () => '2049:${identities.length + 1}',
    );
    return '"identity":"$placeholder"';
  });
  await _expectFixture(name, text);
}

/// The four-key note an earlier relocation left in `unfinished-moves`.
void _notes(StoreFixture Function() fixture, String Function() root) {
  const name = 'relocation_note';
  const id = '1-abc';
  group(name, () {
    test('is finished by the next recovery', () async {
      // Older builds spelt the note under the configured Documents folder.
      final kid = p.join(fixture().documents.path, 'repertoires', 'KID');
      final from = p.join(kid, 'A.pgn');
      final to = p.join(kid, 'C.pgn');
      await fixture().put(DocumentRef(from), _a);
      final identity = (await probeDocument(from) as FileFound).identity;
      final reviews = File(p.join(fixture().documents.path, reviewsFile));
      await reviews.writeAsString('$reviewsHeader\n${_review(from)}');
      await File(from).rename(to);
      final note = File(
        p.join(fixture().support.path, 'unfinished-moves', '$id.json'),
      );
      await note.parent.create(recursive: true);
      await note.writeAsString(
        (await _rooted(
          name,
          fixture().root.path,
        )).replaceAll('2049:1234567', identity),
      );
      await RelocationNotes(
        documents: fixture().documents,
        support: fixture().support,
      ).finishOwed();
      expect(await note.exists(), isFalse);
      expect(fixture().quarantined(), isEmpty);
      expect(RecoveryLedger.of(fixture().support).owed, isEmpty);
      expect(await reviews.readAsString(), '$reviewsHeader\n${_review(to)}');
    });

    test('decodes and encodes again to the same bytes', () async {
      final text = await _fixture(name).readAsString();
      final note = decodeMoveNote(jsonDecode(text), id);
      expect(jsonEncode(note.toJson()), text);
    });

    test('with a version it does not know is refused', () async {
      final json = jsonDecode(await _fixture(name).readAsString()) as Map;
      expect(
        () => decodeMoveNote({...json, 'version': 2}, id),
        throwsA(isA<RecoveryRequired>()),
      );
    });
  }, skip: Platform.isWindows ? _posixOnly : false);
}

/// A tournament's `.v2-pending.json`: version 2 as written today, and
/// version 1, which kept the whole earlier PGN, as earlier builds wrote it.
void _tournaments(StoreFixture Function() fixture) {
  final initial = Tournament({
    'version': 1,
    'id': 'test',
    'createdAt': '2026-09-27',
    'status': 'pending',
    'config': {
      'name': 'Match',
      'engines': [
        TournamentEngine.bundled().json,
        TournamentEngine.bundled().json,
      ],
    },
    'games': <Object>[],
  });
  final after = initial.changed({'status': 'running'});
  group('tournament', () => _tournamentRecords(fixture, initial, after));
}

void _tournamentRecords(
  StoreFixture Function() fixture,
  Tournament initial,
  Tournament after,
) {
  const earlier = '[Event "Match"]\n[Result "*"]\n\n*\n';
  const games = '[Event "Match"]\n[Result "*"]\n\n1. e4 *\n';
  var stop = false;
  late Directory root;
  late FileTournaments store;
  File pending() => File(p.join(root.path, 'test', '.v2-pending.json'));
  File metadata() => File(p.join(root.path, 'test', 'tournament.json'));

  setUp(() async {
    stop = false;
    root = Directory(p.join(fixture().documents.path, 'engine_tournaments'));
    store = FileTournaments(
      root: root,
      support: fixture().support,
      documents: fixture().store,
      afterPgn: () async {
        if (stop) throw StateError('stopped after the PGN');
      },
    );
    await store.create(initial);
    await fixture().put(store.games('test'), earlier);
  });

  test('tournament_pending_v2 is what a save writes down today', () async {
    stop = true;
    await store.save(initial, after, games, expectedPgn: earlier);
    final text = await pending().readAsString();
    await _expectFixture('tournament_pending_v2', text);
    if (!_update) return;
    // Version 1 as the earlier builds encoded it, from the same save.
    final v2 = jsonDecode(text) as Map<String, Object?>;
    await _expectFixture(
      'tournament_pending_v1',
      jsonEncode({
        'version': 1,
        'before': v2['before'],
        'after': v2['after'],
        'pgnBefore': earlier,
        'pgnAfter': v2['pgnAfter'],
      }),
    );
  });

  for (final version in [1, 2]) {
    test('tournament_pending_v$version is finished by the next list', () async {
      final text = await _fixture(
        'tournament_pending_v$version',
      ).readAsString();
      await pending().writeAsString(text);
      final listed = await store.list() as TournamentSaved<List<Tournament>>;
      expect(listed.warnings, isEmpty);
      expect(listed.value.single.json['status'], 'running');
      expect(await File(store.games('test').path).readAsString(), games);
      expect(await pending().exists(), isFalse);
    });
  }

  test(
    'a pending tournament record of an unknown version is set aside',
    () async {
      final json =
          jsonDecode(await _fixture('tournament_pending_v2').readAsString())
              as Map;
      final before = await metadata().readAsString();
      await pending().writeAsString(jsonEncode({...json, 'version': 3}));
      final listed = await store.list() as TournamentSaved<List<Tournament>>;
      expect(listed.warnings, hasLength(1));
      expect(await metadata().readAsString(), before);
      expect(await File(store.games('test').path).readAsString(), earlier);
      expect(fixture().quarantined(), hasLength(1));
    },
  );
}

/// The training queue earlier builds kept in `training-writes`: a finished
/// receipt is removed, and a record that never finished is set aside whole,
/// whatever its version, never replayed.
void _trainingQueue(StoreFixture Function() fixture) =>
    group('training_write', () => _trainingRecords(fixture));

void _trainingRecords(StoreFixture Function() fixture) {
  Future<File> leave(String name) async {
    final file = File(
      p.join(fixture().support.path, 'training-writes', '$name.json'),
    );
    await file.parent.create(recursive: true);
    return file.writeAsString(
      await _fixture('training_write_$name').readAsString(),
    );
  }

  TrainingQueueMigration migration() => TrainingQueueMigration(
    documents: fixture().documents,
    support: fixture().support,
  );

  test('a finished training receipt is removed', () async {
    final receipt = await leave('complete');
    await migration().recover();
    expect(await receipt.exists(), isFalse);
    expect(fixture().quarantined(), isEmpty);
  });

  test('an unfinished training record is set aside, not replayed', () async {
    await leave('incomplete');
    await migration().recover();
    expect(fixture().quarantined().map((f) => p.basename(f.path)), [
      'training-writes-incomplete.json',
    ]);
    expect(
      File(p.join(fixture().documents.path, reviewsFile)).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(fixture().support.path, 'training-writes')).existsSync(),
      isFalse,
    );
  });
}
