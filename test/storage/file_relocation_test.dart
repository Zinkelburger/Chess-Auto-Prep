import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:document_file_io/document_file_io.dart'
    show NativeCall, runWithNativeCalls;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('file move commits explicit book selectors before returning', () async {
    final from = fixture.ref('repertoires/Course/Main.pgn');
    final to = fixture.ref('repertoires/Course/Renamed.pgn');
    final revision = await fixture.put(from, oneGame('1. e4'));
    final books = File(p.join(fixture.support.path, 'books.json'));
    await books.writeAsString(
      jsonEncode({
        'version': 1,
        'active': 'book',
        'unknown': {'keep': true},
        'books': [
          {
            'id': 'book',
            'name': 'My book',
            'repertoires': <String>[],
            'chapters': [
              {'path': 'Course/Main.pgn', 'section': null, 'annotation': 7},
            ],
          },
        ],
      }),
    );
    expect(
      await fixture.store.move(from, to, expected: revision),
      isA<Moved>(),
    );
    final actual = jsonDecode(await books.readAsString()) as Map;
    expect(actual['books'][0]['chapters'][0], {
      'path': 'Course/Renamed.pgn',
      'section': null,
      'annotation': 7,
    });
    expect(actual['unknown'], {'keep': true});
    expect(await File(from.path).exists(), isFalse);
    expect(await File(to.path).readAsString(), oneGame('1. e4'));
  });

  test('unreadable books never stop a chapter or study move', () async {
    final books = File(p.join(fixture.support.path, 'books.json'));
    await books.writeAsString('not json');
    final chapter = fixture.ref('repertoires/Course/Main.pgn');
    final study = fixture.ref('studies/Study.pgn');
    final chapterRevision = await fixture.put(chapter, oneGame('1. e4'));
    final studyRevision = await fixture.put(study, oneGame('1. d4'));
    expect(
      await fixture.store.move(
        chapter,
        fixture.ref('repertoires/Course/Renamed.pgn'),
        expected: chapterRevision,
      ),
      isA<Moved>(),
    );
    expect(
      await fixture.store.move(
        study,
        fixture.ref('studies/Renamed.pgn'),
        expected: studyRevision,
      ),
      isA<Moved>(),
    );
    expect(await books.readAsString(), 'not json');
  });

  test('a selector this build refuses does not stop other moves', () async {
    final books = File(p.join(fixture.support.path, 'books.json'));
    final text = jsonEncode({
      'version': 1,
      'active': null,
      'books': [
        {
          'id': 'book',
          'name': 'My book',
          'repertoires': <String>[],
          'chapters': [
            {'path': r'Folder/a\b.pgn', 'section': null},
            {'path': 'Course/Main.pgn', 'section': null},
          ],
        },
      ],
    });
    await books.writeAsString(text);
    final from = fixture.ref('repertoires/Course/Main.pgn');
    final revision = await fixture.put(from, oneGame('1. e4'));
    expect(
      await fixture.store.move(
        from,
        fixture.ref('repertoires/Course/Renamed.pgn'),
        expected: revision,
      ),
      isA<Moved>(),
    );
    final book =
        ((jsonDecode(await books.readAsString())
                    as Map<String, Object?>)['books']!
                as List<Object?>)
            .single;
    expect((book! as Map<String, Object?>)['chapters'], [
      {'path': r'Folder/a\b.pgn', 'section': null},
      {'path': 'Course/Renamed.pgn', 'section': null},
    ]);
  });

  test('books that are not UTF-8 never stop a move', () async {
    final books = File(p.join(fixture.support.path, 'books.json'));
    const bytes = [0x7b, 0xff, 0xfe, 0x7d];
    await books.writeAsBytes(bytes);
    final from = fixture.ref('repertoires/Course/Main.pgn');
    final revision = await fixture.put(from, oneGame('1. e4'));
    expect(
      await fixture.store.move(
        from,
        fixture.ref('repertoires/Course/Renamed.pgn'),
        expected: revision,
      ),
      isA<Moved>(),
    );
    expect(await books.readAsBytes(), bytes);
  });

  test(
    'unreadable attempt naming the moved chapter refuses before the PGN moves',
    () async {
      final from = fixture.ref('repertoires/Course/Main.pgn');
      final to = fixture.ref('repertoires/Course/Renamed.pgn');
      final revision = await fixture.put(from, oneGame('1. e4'));
      final attempts = File(p.join(fixture.documents.path, attemptsFile));
      final torn = 'not an accepted attempt ${from.path}\n';
      await attempts.writeAsString(torn);
      expect(
        await fixture.store.move(from, to, expected: revision),
        isA<IoFailure>(),
      );
      expect(await File(from.path).readAsString(), oneGame('1. e4'));
      expect(await File(to.path).exists(), isFalse);
      expect(await attempts.readAsString(), torn);
    },
  );

  test('unreadable attempt naming nothing leaves the move to finish', () async {
    final from = fixture.ref('repertoires/Course/Main.pgn');
    final to = fixture.ref('repertoires/Course/Renamed.pgn');
    final revision = await fixture.put(from, oneGame('1. e4'));
    final attempts = File(p.join(fixture.documents.path, attemptsFile));
    await attempts.writeAsString('not an accepted attempt\n');
    expect(
      await fixture.store.move(from, to, expected: revision),
      isA<Moved>(),
    );
    expect(await File(from.path).exists(), isFalse);
    expect(await File(to.path).readAsString(), oneGame('1. e4'));
    expect(await attempts.readAsString(), 'not an accepted attempt\n');
  });
  test(
    'aliased training keys recover alongside canonical keys after a move',
    () async {
      final alias = Directory(p.join(fixture.root.path, 'Documents-alias'));
      await Link(alias.path).create(fixture.documents.path);
      final from = fixture.ref('repertoires/Course/Main.pgn');
      final to = fixture.ref('repertoires/Course/Renamed.pgn');
      final original = await fixture.put(from, oneGame('1. e4'));
      final aliasFrom = DocumentRef(
        p.join(alias.path, 'repertoires/Course/Main.pgn'),
      );
      final aliasTo = DocumentRef(
        p.join(alias.path, 'repertoires/Course/Renamed.pgn'),
      );
      final attempts = File(p.join(fixture.documents.path, attemptsFile));
      await attempts.writeAsString(
        [from.path, aliasFrom.path]
            .map((path) => jsonEncode({'repertoireId': path, 'keep': 7}))
            .join('\n'),
      );
      final interrupted = PgnFileStore(
        documents: alias,
        support: fixture.support,
        relocationHook: (step) async {
          if (step == FileRelocationStep.document)
            throw StateError('lost acknowledgement');
        },
      );
      expect(
        await interrupted.move(
          aliasFrom,
          aliasTo,
          expected: original,
          operationId: 'alias-move',
        ),
        isA<IoFailure>(),
      );
      // A canonical-root instance recovers the spelling captured by the first app.
      for (var restart = 0; restart < 2; restart++) {
        final reopened = PgnFileStore(
          documents: fixture.documents,
          support: fixture.support,
        );
        expect(await reopened.open(to), isA<Opened>());
        expect(
          (await attempts.readAsLines()).map(
            (line) => jsonDecode(line)['repertoireId'],
          ),
          [to.path, aliasTo.path],
        );
      }
      expect(await File(from.path).exists(), isFalse);
      // A finished move leaves no record behind.
      expect(
        await File(
          p.join(fixture.support.path, 'relocation-writes', 'alias-move.json'),
        ).exists(),
        isFalse,
      );
    },
    skip: !Platform.isLinux,
  );

  group('a move deferred after its PGN was renamed', () {
    late DocumentRef from;
    late DocumentRef to;
    late PgnFileStore owner;
    var held = true;
    var ahead = Duration.zero;

    setUp(() async {
      from = fixture.ref('repertoires/Course/Main.pgn');
      to = fixture.ref('repertoires/Course/Renamed.pgn');
      final revision = await fixture.put(from, oneGame('1. e4'));
      await fixture.train(from);
      held = true;
      ahead = Duration.zero;
      owner = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
        recoveryClock: () => DateTime.now().add(ahead),
        relocationHook: (step) async {
          if (held && step == FileRelocationStep.reviews) {
            throw const FileSystemException('held open by another program');
          }
        },
      );
      expect(
        await owner.move(from, to, expected: revision, operationId: 'held'),
        isA<IoFailure>(),
      );
      expect(await File(to.path).exists(), isTrue);
    });

    PgnFileStore reopened() =>
        PgnFileStore(documents: fixture.documents, support: fixture.support);

    for (final restart in [false, true]) {
      final session = restart ? 'after a restart' : 'in the same session';
      for (final change in _unreadable) {
        test('finishes $session over ${change.name}', () async {
          final file = File(p.join(fixture.documents.path, change.file));
          await change.apply(file, from.path, to.path);
          final bytes = await file.readAsBytes();
          held = false;
          final store = restart ? reopened() : owner;
          expect(await store.open(to), isA<Opened>());
          await _finishedWithout(fixture, change.file, bytes, from, to);
          await _movesAgain(fixture, store, to, change.file);
        });
      }
    }

    test('finishes over ANSI reviews once saves were let pass', () async {
      final opened = await owner.open(to) as Opened;
      ahead = const Duration(minutes: 6);
      expect(
        await owner.save(
          to,
          oneGame('1. e4 e5'),
          expected: opened.revision,
          scope: GamesEdited(GamesWritten(rewritten: const {0})),
        ),
        isA<Saved>(),
      );
      expect(
        fixture.unfinishedMoves().map((entry) => p.extension(entry.path)),
        contains('.following'),
      );
      final ansi = _unreadable.last;
      final file = File(p.join(fixture.documents.path, ansi.file));
      await ansi.apply(file, from.path, to.path);
      final bytes = await file.readAsBytes();

      held = false;
      expect((await owner.open(to) as Opened).text, oneGame('1. e4 e5'));
      await _finishedWithout(fixture, ansi.file, bytes, from, to);
      await _movesAgain(fixture, owner, to, ansi.file);
    });

    test('stays owed while a training file cannot be read for now', () async {
      final attempts = File(p.join(fixture.documents.path, attemptsFile));
      await attempts.writeAsString(
        _tornAnswer(from.path),
        mode: FileMode.append,
      );
      final bytes = await attempts.readAsBytes();
      final reviews = p.join(
        fixture.documents.resolveSymbolicLinksSync(),
        reviewsFile,
      );
      var reads = 0;
      final opened = await runWithNativeCalls(<R>(
        NativeCall call,
        List<String> paths,
        Future<R> Function() real,
      ) {
        // The first read of the reviews passes, every later one fails.
        if (call == NativeCall.observeFile &&
            paths.first == reviews &&
            reads++ > 0) {
          throw FileSystemException('held open by another program', reviews);
        }
        return real();
      }, () => reopened().open(to));
      expect(opened, isA<Opened>());
      expect(fixture.unfinishedMoves(), isNotEmpty);
      expect(fixture.quarantined(), isEmpty);

      expect(await reopened().open(to), isA<Opened>());
      await _finishedWithout(fixture, attemptsFile, bytes, from, to);
    });
  }, skip: !Platform.isLinux);

  group('after a move failed once its PGN was renamed', () {
    late DocumentRef a;
    late DocumentRef b;
    late DocumentRef c;
    late Revision revision;
    late bool armed;
    Future<void> failOnce(FileRelocationStep step) async {
      if (armed && step == FileRelocationStep.reviews) {
        armed = false;
        throw const FileSystemException('held open by another program');
      }
    }

    setUp(() async {
      a = fixture.ref('repertoires/Course/A.pgn');
      b = fixture.ref('repertoires/Course/B.pgn');
      c = fixture.ref('repertoires/Course/C.pgn');
      revision = await fixture.put(a, oneGame('1. e4'));
      await fixture.train(a);
      armed = true;
    });

    PgnFileStore store() => PgnFileStore(
      documents: fixture.documents,
      support: fixture.support,
      relocationHook: failOnce,
    );

    test('the next move carries the rows the failed one owed', () async {
      final owner = store();
      expect(await owner.move(a, b, expected: revision), isA<IoFailure>());
      expect(
        await owner.move(b, c, expected: await fixture.revisionOf(b)),
        isA<Moved>(),
      );
      final reopened = PgnFileStore(
        documents: fixture.documents,
        support: fixture.support,
      );
      expect(await reopened.open(c), isA<Opened>());
      expect(fixture.quarantined(), isEmpty);
      expect(fixture.unfinishedMoves(), isEmpty);
      await fixture.expectTrained(c);
    });

    test('asking for the same move again leaves nothing unfinished', () async {
      final owner = store();
      expect(await owner.move(a, b, expected: revision), isA<IoFailure>());
      expect(await owner.move(a, b, expected: revision), isA<Conflict>());
      expect(fixture.unfinishedMoves(), isEmpty);
      await fixture.expectTrained(b);
    });

    test('a later move of either end finishes it first', () async {
      final owner = FileRelocations(
        documents: fixture.documents,
        support: fixture.support,
        testHook: failOnce,
      );
      expect(
        await owner.move(a, b, expected: revision, operationId: 'first'),
        isA<IoFailure>(),
      );
      expect(
        await owner.move(
          b,
          c,
          expected: await fixture.revisionOf(b),
          operationId: 'second',
        ),
        isA<Moved>(),
      );
      expect(fixture.unfinishedMoves(), isEmpty);
      expect(fixture.quarantined(), isEmpty);
      await fixture.expectTrained(c);
    });
  }, skip: !Platform.isLinux);
}

/// What another program leaves in a training file between a move's failed
/// attempt and its next one, which no plan can read: the file cannot follow.
typedef _Unreadable = ({
  String name,
  String file,
  Future<void> Function(File file, String from, String to) apply,
});

final _unreadable = <_Unreadable>[
  (
    name: 'a torn answer naming the chapter',
    file: attemptsFile,
    apply: (file, from, to) =>
        file.writeAsString(_tornAnswer(from), mode: FileMode.append),
  ),
  (
    name: 'a reviews row of the wrong width naming the chapter',
    file: reviewsFile,
    apply: (file, from, to) =>
        file.writeAsString('"$from",line,Main\n', mode: FileMode.append),
  ),
  // A spreadsheet saving the reviews in its own encoding.
  (
    name: 'reviews that are no longer UTF-8',
    file: reviewsFile,
    apply: (file, from, to) async => file.writeAsBytes([
      ...await file.readAsBytes(),
      ...latin1.encode(
        '$to,caf\u00e9,Caf\u00e9,2.5,1,2026-09-01T00:00:00Z,good,'
        '2026-08-31T00:00:00Z,1,0,false\n',
      ),
    ]),
  ),
];

/// The old app killed while appending an answer for [path].
String _tornAnswer(String path) => '{"repertoireId":${jsonEncode(path)},"li';

/// The move to [to] finished, with [file] left holding [bytes] and the
/// record kept in quarantine rather than owed; the other training files
/// and the book followed.
Future<void> _finishedWithout(
  StoreFixture fixture,
  String file,
  List<int> bytes,
  DocumentRef from,
  DocumentRef to,
) async {
  expect(fixture.unfinishedMoves(), isEmpty);
  expect(
    fixture.quarantined().map((entry) => p.basename(entry.path)),
    contains('relocation-writes-held.json'),
  );
  expect(await File(p.join(fixture.documents.path, file)).readAsBytes(), bytes);
  for (final other in trainingParticipants.where((name) => name != file)) {
    final text = await File(
      p.join(fixture.documents.path, other),
    ).readAsString();
    expect(text, contains(to.path), reason: other);
    expect(text, isNot(contains(from.path)), reason: other);
  }
  final books =
      jsonDecode(
            await File(
              p.join(fixture.support.path, 'books.json'),
            ).readAsString(),
          )
          as Map<String, Object?>;
  expect(((books['books']! as List).single as Map)['chapters'], [
    {'path': 'Course/Renamed.pgn', 'section': null},
  ]);
}

/// Nothing owed stops [chapter] moving again. A [file] that is not UTF-8
/// refuses it, as it refuses any move, until it is saved as UTF-8 again;
/// then the folder moves too. (A record that may name a chapter in the
/// folder refuses that folder's move before anything moves.)
Future<void> _movesAgain(
  StoreFixture fixture,
  PgnFileStore store,
  DocumentRef chapter,
  String file,
) async {
  final training = File(p.join(fixture.documents.path, file));
  final ansi = !_isUtf8(await training.readAsBytes());
  Future<MoveResult> move() async => store.move(
    chapter,
    fixture.ref('repertoires/Course/Again.pgn'),
    expected: await fixture.revisionOf(chapter),
  );
  if (ansi) {
    expect(((await move()) as IoFailure).detail, contains('not UTF-8'));
    await training.writeAsString(latin1.decode(await training.readAsBytes()));
  }
  expect(await move(), isA<Moved>());
  if (!ansi) return;
  expect(
    await store.moveFolder(
      p.join(fixture.documents.path, 'repertoires', 'Course'),
      p.join(fixture.documents.path, 'repertoires', 'Course2'),
    ),
    isA<FolderMoved>(),
  );
}

bool _isUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}
