// Commands on the standard profile that more than one fault scenario runs,
// with the reads that show them: a line of KID's main chapter rated, and
// the Books owner of a session. Each fixes its inputs, so a retry, or the
// same command in another run, sends the same rows.
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/training_rows.dart' show asWritten;
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:chess_auto_prep/workspace/books.dart';

import '../fixtures.dart';
import '../profile/standard_profile.dart';
import 'stores.dart';

/// The ids KID's main chapter trains its lines under: the first has a
/// review, the second a streak for its move at ply 1.
final _ids = trainedIdsOf(parseChapter(name: 'Main', text: blackChapter));

/// Line [n] of the chapter at [relative] (KID's main chapter, wherever a
/// move put it).
LineKey mainLine(Stores s, int n, [String relative = kidMain]) =>
    (source: s.profile.document(relative), id: _ids[n]!);

typedef _Rating = ({
  Change<Review> review,
  Change<MoveStreak> streak,
  HistoryRow history,
});

/// What the trainer read before the user rated: the chapter's rows and
/// sources. It is the trainer's earlier load, not part of the command, so
/// it is read around the trace: a fault in the command never changes what
/// the command was asked to write.
Future<ProgressLoaded> admittedTraining(Stores s) => Zone.root.run(() async {
  final store = TrainingStore(
    Directory(s.profile.documents),
    support: Directory(s.profile.support),
  );
  return await store.read({s.profile.document(kidMain)}) as ProgressLoaded;
});

Future<(ProgressOperation, _Rating)> _admitRating(Stores s) async {
  final loaded = await admittedTraining(s);
  final reviewed = loaded.reviews[mainLine(s, 0)]!;
  return (
    ProgressOperation(sources: loaded.sources),
    (
      review: (
        before: reviewed,
        after: asWritten(
          reviewed.copyWith(
            lastRating: 'easy',
            intervalDays: 6,
            due: DateTime.utc(2026, 10, 5, 8),
            lastReviewed: DateTime.utc(2026, 9, 29, 8),
            passes: reviewed.passes + 1,
          ),
        ),
      ),
      streak: (
        before: loaded.streaks[(line: mainLine(s, 1), ply: 1)],
        after: MoveStreak(
          key: mainLine(s, 1),
          ply: 1,
          streak: 3,
          learned: true,
        ),
      ),
      history: HistoryRow(
        key: mainLine(s, 0),
        at: DateTime.utc(2026, 9, 29, 8),
        rating: 'easy',
        mistake: false,
        kind: HistoryKind.trainer,
      ),
    ),
  );
}

/// The rating's inputs, read as the trainer reads them before the user
/// rates, once per session.
Future<void> admitMainLineRating(Stores s) async {
  await s.once('rating', () => _admitRating(s));
}

/// KID's main chapter's first line rated easy and its second line's move
/// learned: a review, a streak and a history row. A retry sends the same
/// rows under the same operation, accepted once per session.
Future<ProgressWrite> rateMainLine(Stores s) async {
  final (operation, rating) = await s.once('rating', () => _admitRating(s));
  return s.training.write(
    reviews: [rating.review],
    streaks: [rating.streak],
    history: [rating.history],
    operation: operation,
  );
}

/// The rated line's rating and the learned move's streak, as the trainer
/// reads them with KID's main chapter at [relative].
Future<String> ratedMainLine(Stores s, [String relative = kidMain]) async {
  final path = s.profile.document(relative);
  return switch (await s.training.read({path})) {
    ProgressLoaded(:final reviews, :final streaks) =>
      'rated ${reviews[mainLine(s, 0, relative)]?.lastRating}, streak '
          '${streaks[(line: mainLine(s, 1, relative), ply: 1)]?.streak}',
    ProgressUnreadable(:final file, :final line) => 'unreadable $file:$line',
    ProgressFailed() => 'failed',
  };
}

/// The session's Books owner, on the store's books file and gate.
Books booksOwner(Stores s) => s.once(
  'books',
  () => Books(store: s.documents.books, root: s.profile.repertoires),
);

/// Each book's name, repertoires and chapters, and the active one, as
/// books.json reads now.
Future<String> bookList(Stores s) async {
  final BookList list;
  try {
    list = (await s.documents.books.snapshot()).value;
  } on Exception {
    return 'unreadable';
  }
  return describeBooks(list);
}

/// Each book of [list] with its name, repertoires and chapters, and the
/// active one.
String describeBooks(BookList list) {
  String sorted(Iterable<String> names) => (names.toList()..sort()).join(', ');
  return [
    for (final book in list.books)
      '${book.id} "${book.name}": [${sorted(book.repertoires)}] '
          '[${sorted(book.chapters.map((c) => '${c.path}#${c.section}'))}]',
    'active ${list.active}',
  ].join('; ');
}
