// The standard synthetic profile the storage contracts run on: a little of
// everything a real one holds, in the shapes both apps write, so an operation
// on one part can be checked for what it does to all the others.
//
// - repertoires: KID with chapter files and a course file whose chapters are
//   `[ChapterName]` sections, and Benko with a CRLF chapter;
// - a Lichess-style study;
// - the four training files: a BOM, CRLF, 8-, 10- and 11-column review rows,
//   attempt lines carrying keys no app writes, rows for chapters no scenario
//   touches, and one row whose chapter was gone before any scenario ran;
// - books.json with unknown keys and section selectors;
// - kept versions and a deleted chapter, made by the real store, whose
//   training row and book selector the delete repointed, and a quarantined
//   record;
// - the downloaded games cache and settings.json.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:path/path.dart' as p;

import '../fixtures.dart';
import 'profile.dart';

/// The standard profile's documents, relative to Documents.
const kidMain = 'repertoires/KID/Main.pgn';
const kidSidelines = 'repertoires/KID/Sidelines.pgn';
const kidCourse = 'repertoires/KID/KID course.pgn';
const benkoAccepted = 'repertoires/Benko/Accepted.pgn';
const benkoDeclined = 'repertoires/Benko/Declined.pgn';
const endgameStudy = 'studies/Endgames.pgn';
const downloadedGames = 'games_library/lichess_me.pgn';

/// Deleted while seeding, so it lies in KID's `.cap-pgn-history/`, at
/// [kidDeletedAside].
const kidDeleted = 'repertoires/KID/Old.pgn';
const _deleteId = '1756720000000000-5eed';
const kidDeletedAside = 'repertoires/KID/.cap-pgn-history/$_deleteId-Old.pgn';

/// The course's sections, in file order.
const kidCourseSections = ['Mar del Plata', 'Four Pawns'];

/// Fills [profile], which must be empty, with the standard profile. Runs
/// on the real disk; call it outside a FaultyDisk run.
Future<void> seedStandardProfile(Profile profile) async {
  final documents = {
    kidMain: _kidMainEarlier,
    kidSidelines: emptyChapter,
    kidCourse: _kidCourse,
    benkoAccepted: _benkoAccepted,
    benkoDeclined: _benkoDeclined,
    endgameStudy: _study,
    downloadedGames: _downloaded,
    kidDeleted: kidDeletedText,
  };
  for (final MapEntry(:key, :value) in documents.entries) {
    final file = File(profile.document(key));
    await file.parent.create(recursive: true);
    await file.writeAsString(value);
  }
  final store = PgnFileStore(
    documents: Directory(profile.documents),
    support: Directory(profile.support),
  );
  await _keepVersion(store, profile);
  await _writeTraining(profile);
  await File(profile.books).writeAsString(_books);
  await _delete(store, profile);
  await File(profile.settings).writeAsString(_settings);
  final aside = Directory(
    profile.supportFile('recovery-quarantine/20260901T101112123456Z'),
  );
  await aside.create(recursive: true);
  await File(
    p.join(aside.path, 'compound-writes-1756720000000000-ab12cd.json'),
  ).writeAsString('{"version": 99, "participants": []}');
  await File(p.join(aside.path, 'Main.pgn')).writeAsString(_kidMainOldest);
}

/// The standard profile with books.json as this build writes it. The Books
/// owner sets aside a books.json it cannot read whole before its first write
/// replaces it, by design (books_codec_laws_test.dart covers that), so a
/// scenario about its writes starts from one it can.
Future<void> seedWithWrittenBooks(Profile profile) async {
  await seedStandardProfile(profile);
  final file = File(profile.books);
  await file.writeAsString(BookList.decode(await file.readAsString()).encode());
}

/// The ids the chapter at [relative] trains its lines under, in file order.
List<String> standardTrainedIds(Profile profile, String relative) =>
    trainedIdsOf(
      parseChapter(
        name: 'chapter',
        text: File(profile.document(relative)).readAsStringSync(),
      ),
    ).nonNulls.toList();

/// A save of KID's main chapter through the real store, which keeps the
/// earlier version.
Future<void> _keepVersion(PgnFileStore store, Profile profile) async {
  final main = DocumentRef(profile.document(kidMain));
  final saved = await store.save(
    main,
    blackChapter,
    expected: await _revision(main),
    scope: GamesEdited(GamesWritten(rewritten: const {0})),
  );
  if (saved is! Saved) throw StateError('seeding the standard profile: $saved');
}

/// A delete of the old chapter through the real store, which sets it aside
/// and repoints its training row and book selector to where it lies.
Future<void> _delete(PgnFileStore store, Profile profile) async {
  final old = DocumentRef(profile.document(kidDeleted));
  final deleted = await store.delete(
    old,
    expected: await _revision(old),
    operationId: _deleteId,
  );
  if (deleted is! Deleted) {
    throw StateError('seeding the standard profile: $deleted');
  }
}

Future<Revision> _revision(DocumentRef ref) async =>
    (await probeDocument(ref.path) as FileFound).revision;

Future<void> _writeTraining(Profile profile) async {
  String at(String relative) => profile.document(relative);
  final main = standardTrainedIds(profile, kidMain);
  final course = standardTrainedIds(profile, kidCourse);
  final accepted = standardTrainedIds(profile, benkoAccepted);
  final declined = standardTrainedIds(profile, benkoDeclined);
  final old = standardTrainedIds(profile, kidDeleted);
  const due = '2026-09-16T08:12:00.000Z';
  const last = '2026-09-10T08:12:00.000Z';
  String row(List<String> cells) => encodeCsvRecord(cells);
  // Eight columns, then pass and fail counts (10) and the exclusion flag (11).
  String review(
    String path,
    String id,
    String name,
    String rating, [
    List<String> more = const [],
  ]) => row([path, id, name, '2.50', '1.00', due, rating, last, ...more]);
  final reviews = [
    reviewsHeader,
    review(at(kidMain), main[0], 'Main', 'good', ['3', '1', 'false']),
    review(at(kidCourse), course[0], 'Mar del Plata', 'hard', ['1', '2']),
    review(at(benkoAccepted), accepted[1], 'Accepted', 'again'),
    review(at(benkoDeclined), declined[0], 'Declined', 'easy', [
      '4',
      '0',
      'true',
    ]),
    review(
      p.join(profile.repertoires, 'Gone', 'Gone.pgn'),
      'line_gone',
      'Gone',
      'good',
      ['1', '0', 'false'],
    ),
  ];
  final streaks = [
    streaksHeader,
    row([at(kidMain), main[1], '1', '2', '1']),
    row([at(kidCourse), course[2], '3', '0', '0']),
    row([at(benkoDeclined), declined[0], '1', '5', '1']),
    row([at(kidDeleted), old[0], '2', '1', '0']),
  ];
  final history = [
    historyHeader,
    row([at(kidMain), main[0], last, 'good', '0', 'trainer']),
    row([at(benkoAccepted), accepted[0], last, 'hard', '1', 'trainer']),
  ];
  final attempts = [
    _attempt(at(kidCourse), course[1], future: true),
    _attempt(at(benkoDeclined), declined[0], future: false),
  ];
  Future<void> put(String name, String text) =>
      File(profile.training(name)).writeAsString(text);
  await put(reviewsFile, '\uFEFF${reviews.join('\r\n')}\r\n');
  await put(streaksFile, '${streaks.join('\n')}\n');
  // No newline after the last row, as a hand-edited file often ends.
  await put(historyFile, history.join('\n'));
  await put(attemptsFile, '${attempts.join('\n')}\n');
}

/// One answered move; [future] adds keys a later version might write.
String _attempt(String source, String id, {required bool future}) =>
    jsonEncode({
      'repertoireId': source,
      'lineId': id,
      'moveIndex': 1,
      'fen': 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
      'playedSan': 'Nf6',
      'expectedSan': 'Nf6',
      'correct': true,
      'phase': 'drilling',
      'timestampUtc': '2026-09-10T08:12:00.000Z',
      if (future) 'x_hint': {'shown': false, 'ms': 1200},
    });

/// The main chapter before its first comment was expanded: the version the
/// seeding save keeps.
final _kidMainEarlier = blackChapter.replaceFirst(
  '{The Sicilian [%eval 0.30]}',
  '{The Sicilian}',
);

/// An even older version, set aside by some earlier recovery.
final _kidMainOldest = blackChapter.replaceFirst(
  '{The Sicilian [%eval 0.30]}',
  '',
);

const _kidCourse = '''
// King's Indian
// Color: Black

[Event "King's Indian: Mar del Plata"]
[ChapterName "Mar del Plata"]
[LineID "kid_mdp_main"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 5. Nf3 O-O 6. Be2 e5 7. O-O Nc6 8. d5 Ne7 *

[Event "King's Indian: Mar del Plata"]
[ChapterName "Mar del Plata"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 5. Nf3 O-O 6. Be2 e5 7. O-O Nc6 8. d5 Ne7 9. Ne1 {9. b4 is the Bayonet.} Nd7 *

[Event "King's Indian: Four Pawns"]
[ChapterName "Four Pawns"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 5. f4 O-O 6. Nf3 c5 \$1 *
''';

const _benkoAccepted = '''
// Benko Gambit
// Color: Black

[Event "Benko: Accepted"]
[LineID "benko_accepted_main"]
[Result "*"]

1. d4 Nf6 2. c4 c5 3. d5 b5 4. cxb5 a6 5. bxa6 Bxa6 {[%eval 0.35]} *

[Event "Benko: Accepted"]
[Result "*"]

1. d4 Nf6 2. c4 c5 3. d5 b5 4. cxb5 a6 5. b6 \$6 e6 *
''';

/// Written by a Windows editor: CRLF throughout.
const _benkoDeclined =
    '// Benko Gambit: declined\r\n// Color: Black\r\n\r\n'
    '[Event "Benko: Declined"]\r\n[Result "*"]\r\n\r\n'
    '1. d4 Nf6 2. c4 c5 3. d5 b5 4. Nf3 bxc4 *\r\n';

const _study = '''
[Event "Endgames: Lucena"]
[Site "https://lichess.org/study/abcd1234/efgh5678"]
[Result "*"]
[StudyName "Endgames"]
[ChapterName "Lucena"]
[Orientation "white"]
[FEN "1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1"]
[SetUp "1"]

{Build a bridge.} 1. Rd1+ Ke7 2. Kc7 *

[Event "Endgames: Opposition"]
[Site "https://lichess.org/study/abcd1234/ijkl9012"]
[Result "*"]
[StudyName "Endgames"]
[ChapterName "Opposition"]
[Orientation "black"]

1. e4 e5 *
''';

const _downloaded = '''
[Event "Rated blitz game"]
[Site "https://lichess.org/AbCdEfGh"]
[White "me"]
[Black "them"]
[Result "1-0"]

1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0
''';

/// The chapter [kidDeleted] held before it was deleted.
const kidDeletedText = '[Event "Old"]\n[Result "*"]\n\n1. d4 Nf6 2. Bg5 *\n';

const _books = '''
{
  "version": 1,
  "active": "prep",
  "x_sync": {"device": "laptop"},
  "books": [
    {
      "id": "prep",
      "name": "Club prep",
      "x_colour": "black",
      "repertoires": ["Benko"],
      "chapters": [
        {"path": "KID/Main.pgn", "section": null},
        {"path": "KID/KID course.pgn", "section": "Mar del Plata"},
        {"path": "KID/KID course.pgn", "section": "Four Pawns", "x_pinned": true},
        {"path": "KID/Old.pgn"}
      ]
    }
  ]
}
''';

const _settings = '{"engineThreads": 2, "x_future": {"panel": "left"}}\n';
