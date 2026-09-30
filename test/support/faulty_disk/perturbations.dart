// Changes another program makes to a profile while this app is down: after
// a crash left an operation half done, and before the restart finishes it.
// Each says what recovery must then do, from "How a save and its recovery
// work" in docs/ARCHITECTURE_RENEWAL.md.
//
// Another program sees the files where they are now, so a change to a
// chapter an operation moves names it at whichever end of the move it
// finds: [chapters] lists the places, first the one before the command.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:path/path.dart' as p;

import '../profile/profile.dart';
import '../profile/profile_snapshot.dart';
import '../profile/standard_profile.dart';

/// What recovery must do with an operation a perturbation touched.
enum Expected {
  /// Finish it over the change (re-planned): the command's result reads
  /// back, nothing is quarantined, and the change is kept.
  finished,

  /// "Anything else (an edit by another program) → the record and its data
  /// go to recovery-quarantine/": nothing of the record is applied over the
  /// change, which stays exactly as the other program left it.
  quarantinedWhole,

  /// As [quarantinedWhole], and "the files it had already rewritten are put
  /// back": every file the record changed holds what it held before the
  /// command, or what the crash left it holding.
  putBack,

  /// Finished, with a training file whose records no plan can read ("not
  /// their format at all") left as it is: every other file holds what the
  /// command wrote, the changed file keeps exactly the bytes the change
  /// left, and the finished record is kept in recovery-quarantine/.
  finishedNotFollowed,
}

final class Perturbation {
  const Perturbation(
    this.name,
    this.apply, {
    required this.expect,
    this.expectIn,
    this.kept,
    this.movedAgain,
  });

  /// A name without `/`, for the case's key.
  final String name;

  /// Runs on the real disk between the crash and the reopen.
  final Future<void> Function(Profile profile) apply;
  final Expected expect;

  /// What recovery must do given the profile as the change left it, when
  /// that depends on how far the crash got; [expect] otherwise.
  final Expected Function(ProfileSnapshot perturbed)? expectIn;

  /// What recovery must do after this change left [perturbed].
  Expected expectFor(ProfileSnapshot perturbed) =>
      expectIn?.call(perturbed) ?? expect;

  /// How the reopened profile lost the change, or null while it still
  /// holds it (followed to where a finished recovery moved it).
  final String? Function(ProfileSnapshot state)? kept;

  /// Moves the chapter the operation moved once more, after the restarts,
  /// and says why it could not, or null when it moved: a record still owed
  /// would refuse it.
  final Future<String?> Function(Profile profile)? movedAgain;
}

/// books.json changed by another copy of the app: a key this build does not
/// know added at the top, the books themselves unchanged. Book selectors
/// follow what they point at, as they are now.
const booksEditedMeanwhile = Perturbation(
  'books.json edited meanwhile',
  _editBooks,
  expect: Expected.finished,
);

Future<void> _editBooks(Profile profile) async {
  final file = File(profile.books);
  final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
  json['x_meanwhile'] = {'device': 'desktop'};
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}

/// The course file changed in a text editor: a game added at its end, as
/// it is on disk now, whichever side of the crash that is.
Perturbation courseEditedElsewhere(String relative) => Perturbation(
  'course edited elsewhere',
  (profile) => _appendGame(profile, [relative]),
  expect: Expected.quarantinedWhole,
);

/// A PGN the operation changes or moves, edited in a text editor wherever
/// it is now: a game added at its end. [expectIn], when given, decides what
/// recovery must do from where the edit found the chapter.
Perturbation participantEditedElsewhere(
  List<String> chapters, {
  Expected expect = Expected.quarantinedWhole,
  Expected Function(ProfileSnapshot perturbed)? expectIn,
}) => Perturbation(
  'participant edited elsewhere',
  (profile) => _appendGame(profile, chapters),
  expect: expect,
  expectIn: expectIn,
  kept: (state) =>
      (state.text('Documents/${_whereIn(state, chapters)}') ?? '').contains(
        _addedGame,
      )
      ? null
      : 'the added game is gone',
);

const _addedGame = '[Event "Added in an editor"]';

Future<void> _appendGame(Profile profile, List<String> chapters) async {
  final file = File(profile.document(_whereNow(profile, chapters)));
  final text = await file.readAsString();
  await file.writeAsString(
    '${text.trimRight()}\n\n$_addedGame\n[Result "*"]\n\n'
    '1. d4 Nf6 2. Nf3 g6 *\n',
  );
}

/// The old app rating the line [lineId] of the chapter at [chapters]: a
/// history row appended, keyed at wherever the chapter is now. Recovery
/// that finishes keeps the row, pointing at where the chapter ends up, or
/// at [movedTo] when the operation moves the line there.
Perturbation trainingAnswer(
  String name, {
  required List<String> chapters,
  required String lineId,
  required Expected expect,
  String? movedTo,
}) => Perturbation(
  name,
  (profile) => _answer(profile, chapters, lineId),
  expect: expect,
  kept: (state) {
    final row = _answerRow(
      Profile(state.root),
      movedTo ?? _whereIn(state, chapters),
      lineId,
    );
    final history = state.text('Documents/$historyFile') ?? '';
    return history.contains(row) ? null : 'no history row $row';
  },
);

/// The old app rating a Benko line no relocation scenario moves.
Perturbation unrelatedAnswer({required Expected expect}) => trainingAnswer(
  'answer for an unrelated line',
  chapters: [benkoAccepted],
  lineId: 'benko_accepted_main',
  expect: expect,
);

const _answeredAt = '2026-09-29T07:00:00.000Z';

String _answerRow(Profile profile, String relative, String lineId) =>
    encodeCsvRecord([
      profile.document(relative),
      lineId,
      _answeredAt,
      'good',
      '0',
      'trainer',
    ]);

Future<void> _answer(
  Profile profile,
  List<String> chapters,
  String lineId,
) async {
  final row = _answerRow(profile, _whereNow(profile, chapters), lineId);
  await _append(File(profile.training(historyFile)), '$row\n');
}

/// An answer the old app was killed while appending: half a JSON line, no
/// newline after it. It names no chapter any scenario moves.
Perturbation tornAttemptsLine({required Expected expect}) => Perturbation(
  'torn attempts line',
  (profile) => _append(File(profile.training(attemptsFile)), _torn(profile)),
  expect: expect,
  kept: (state) {
    final text = state.text('Documents/$attemptsFile') ?? '';
    return text.contains(_torn(Profile(state.root))) ? null : 'torn line gone';
  },
);

String _torn(Profile profile) =>
    '{"repertoireId":${jsonEncode(profile.document(benkoDeclined))},'
    '"lineId":"torn","moveIn';

/// An answer the old app was killed while appending for the moved chapter
/// at [chapters]' first place: half a JSON line naming it. No plan can read
/// it, so the log does not follow the move; the rest of it does.
Perturbation tornAttemptsLineNamingMoved(List<String> chapters) => Perturbation(
  'torn attempts line naming the moved chapter',
  (profile) => _append(
    File(profile.training(attemptsFile)),
    _tornNaming(profile, chapters.first),
  ),
  expect: Expected.finishedNotFollowed,
  kept: (state) {
    final text = state.text('Documents/$attemptsFile') ?? '';
    final torn = _tornNaming(Profile(state.root), chapters.first);
    return text.contains(torn) ? null : 'torn line gone';
  },
  movedAgain: (profile) => _moveAgain(profile, chapters),
);

String _tornNaming(Profile profile, String relative) =>
    '{"repertoireId":${jsonEncode(profile.document(relative))},"li';

/// A reviews row with three cells naming the moved chapter at [chapters]'
/// first place, written by hand: the reviews do not follow the move.
Perturbation malformedReviewRowNamingMoved(List<String> chapters) =>
    Perturbation(
      'malformed review row naming the moved chapter',
      (profile) => _append(
        File(profile.training(reviewsFile)),
        '${_malformedNaming(profile, chapters.first)}\r\n',
      ),
      expect: Expected.finishedNotFollowed,
      kept: (state) {
        final text = state.text('Documents/$reviewsFile') ?? '';
        final row = _malformedNaming(Profile(state.root), chapters.first);
        return text.contains(row) ? null : 'malformed row gone';
      },
      movedAgain: (profile) => _moveAgain(profile, chapters),
    );

String _malformedNaming(Profile profile, String relative) =>
    encodeCsvRecord([profile.document(relative), 'line', 'Main']);

/// The chapter at the first of [chapters] that is a file, renamed beside
/// itself, as a later command of the user's would.
Future<String?> _moveAgain(Profile profile, List<String> chapters) async {
  final store = PgnFileStore(
    documents: Directory(profile.documents),
    support: Directory(profile.support),
    recoveryRetry: Duration.zero,
  );
  final from = DocumentRef(profile.document(_whereNow(profile, chapters)));
  final opened = await store.open(from);
  if (opened is! Opened) return 'it opened as ${opened.runtimeType}';
  final moved = await store.move(
    from,
    DocumentRef(p.join(p.dirname(from.path), 'Moved again.pgn')),
    expected: opened.revision,
  );
  return switch (moved) {
    Moved() => null,
    IoFailure(:final detail) => detail,
    _ => 'it answered ${moved.runtimeType}',
  };
}

/// A reviews row with three cells, written by hand; no chapter's.
Perturbation malformedReviewRow({required Expected expect}) => Perturbation(
  'malformed review row',
  (profile) => _append(File(profile.training(reviewsFile)), '$_malformed\r\n'),
  expect: expect,
  kept: (state) =>
      (state.text('Documents/$reviewsFile') ?? '').contains(_malformed)
      ? null
      : 'malformed row gone',
);

const _malformed = 'not,a,review';

/// [text] after the last line of [file], starting a line of its own.
Future<void> _append(File file, String text) async {
  final had = await file.exists() ? await file.readAsString() : '';
  final gap = had.isEmpty || had.endsWith('\n') ? '' : '\n';
  await file.writeAsString('$had$gap$text');
}

/// The Books owner saving a new book, active, holding the chapter at
/// [chapters] where it is now; as it writes books.json, from what it could
/// read.
Perturbation booksEditedByOwner({
  required List<String> chapters,
  required Expected expect,
}) => Perturbation(
  'books.json edited by the Books owner',
  (profile) => _addBook(profile, chapters),
  expect: expect,
  kept: (state) {
    final books = BookList.decode(state.text('Support/books.json') ?? '');
    final chapter = _selector(_whereIn(state, chapters));
    final book = books.byId('blitz');
    return books.active == book?.id && book!.chapters.contains(chapter)
        ? null
        : 'the new book does not hold ${chapter.path}';
  },
);

Future<void> _addBook(Profile profile, List<String> chapters) async {
  final file = File(profile.books);
  final books = BookList.decode(await file.readAsString());
  final chapter = _selector(_whereNow(profile, chapters));
  final next = BookList(
    books: [
      ...books.books,
      Book(id: 'blitz', name: 'Blitz', chapters: {chapter}),
    ],
    active: 'blitz',
  );
  await file.writeAsString(next.encode());
}

/// A chapter entry no build can read, added by hand to the first book.
Perturbation badBookEntry({required Expected expect}) => Perturbation(
  'bad book entry',
  _addBadEntry,
  expect: expect,
  kept: (state) {
    final json = jsonDecode(state.text('Support/books.json') ?? '{}');
    final chapters = _firstBook(json as Map<String, Object?>)['chapters'];
    return chapters is List && chapters.any((c) => c is Map && c['path'] == 42)
        ? null
        : 'the bad entry is gone';
  },
);

Future<void> _addBadEntry(Profile profile) async {
  final file = File(profile.books);
  final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
  (_firstBook(json)['chapters']! as List).add({'path': 42, 'section': 'bad'});
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}

/// What a relocation's recovery meets when another program ran first: it
/// re-plans the training rows and books as they now are, keeping each
/// change, and sets the record aside for an edited or unreadable one: a
/// training file whose records naming the chapter cannot be read keeps its
/// bytes, and the rest of the move still finishes.
/// [chapters] are the moved chapter's places, [lineId] one of its lines.
///
/// An edit of the chapter itself sets the record aside whole, except for a
/// [folder] move, which is of the folder, not its files' bytes: once the
/// folder rename landed the edit only goes with it, and recovery finishes.
List<Perturbation> relocationPerturbations({
  required List<String> chapters,
  required String lineId,
  bool folder = false,
}) => [
  trainingAnswer(
    'answer for the moved line',
    chapters: chapters,
    lineId: lineId,
    expect: Expected.finished,
  ),
  unrelatedAnswer(expect: Expected.finished),
  booksEditedByOwner(chapters: chapters, expect: Expected.finished),
  participantEditedElsewhere(
    chapters,
    expectIn: folder
        ? (perturbed) => _whereIn(perturbed, chapters) == chapters.last
              ? Expected.finished
              : Expected.quarantinedWhole
        : null,
  ),
  tornAttemptsLine(expect: Expected.finished),
  malformedReviewRow(expect: Expected.finished),
  tornAttemptsLineNamingMoved(chapters),
  malformedReviewRowNamingMoved(chapters),
  badBookEntry(expect: Expected.finished),
  corruptJournal,
];

/// The folder [from] lies in, removed in a file manager once a move left
/// it empty; one that still holds anything is left alone. A move that
/// landed finishes over it: its old folder has no entry left to flush.
Perturbation emptiedFolderRemoved(String from) =>
    Perturbation('emptied source folder removed', (profile) async {
      final folder = Directory(p.dirname(profile.document(from)));
      if (folder.existsSync() && folder.listSync().isEmpty) {
        await folder.delete();
      }
    }, expect: Expected.finished);

/// Every record the crash left waiting cut to half its bytes, as a disk
/// error or a sync tool can leave one: recovery cannot decode it, so it is
/// set aside and nothing it names is applied.
const corruptJournal = Perturbation(
  'corrupt journal',
  _corruptRecords,
  expect: Expected.quarantinedWhole,
);

Future<void> _corruptRecords(Profile profile) async {
  for (final name in ProfileSnapshot.of(profile).pending) {
    final file = File(p.joinAll([profile.root, ...p.posix.split(name)]));
    final bytes = await file.readAsBytes();
    await file.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
  }
}

Map<String, Object?> _firstBook(Map<String, Object?> json) =>
    (json['books']! as List).first as Map<String, Object?>;

/// A book's selector for the whole chapter file at [relative] to Documents.
BookChapter _selector(String relative) =>
    BookChapter(p.posix.relative(relative, from: 'repertoires'), null);

/// The first of [chapters] (relative to Documents) that is a file now, or
/// the first when none is.
String _whereNow(Profile profile, List<String> chapters) => chapters.firstWhere(
  (chapter) => File(profile.document(chapter)).existsSync(),
  orElse: () => chapters.first,
);

/// The first of [chapters] that is a file in [state], or the first.
String _whereIn(ProfileSnapshot state, List<String> chapters) =>
    chapters.firstWhere(
      (chapter) => state.entries['Documents/$chapter'] is FileEntry,
      orElse: () => chapters.first,
    );
