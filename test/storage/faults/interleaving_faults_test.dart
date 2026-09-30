// Commands of one session run against each other, one held at each change
// it makes while the other runs: a rating held while the trainer reloads
// its scope twice, a chapter moved while a rating is written, and a book
// edited while a chapter moves. Each must end as one of the two serial
// orders ends, and a read begun after the rating was accepted must see it
// ("Later reads see the rating", docs/ARCHITECTURE_RENEWAL.md). See
// interleavings.dart.
@TestOn('linux')
library;

import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/interleavings.dart';
import '../../support/faulty_disk/standard_commands.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/standard_profile.dart';

const _moved = 'repertoires/Benko/Main.pgn';

Future<String> _rate(Stores s) async =>
    '${(await rateMainLine(s)).runtimeType}';

/// The trainer's scope read again twice, as a reload does.
Future<String> _reloadTwice(Stores s) async =>
    '${await ratedMainLine(s)} | ${await ratedMainLine(s)}';

Future<String> _rated(Stores s) => ratedMainLine(s);

const _reloads = Interleaving<Stores>(
  name: 'a rating held while the scope reloads twice',
  seed: seedStandardProfile,
  open: Stores.open,
  prepare: admitMainLineRating,
  held: _rate,
  meanwhile: _reloadTwice,
  read: _rated,
  seesHeld: true,
);

/// KID's main chapter moved into Benko, with its training and books.
Future<String> _move(Stores s) async {
  final moved = await s.documents.move(
    s.ref(kidMain),
    s.ref(_moved),
    expected: revisionOf(s.textNow(kidMain)),
    operationId: 'interleaved-move',
  );
  return '${moved.runtimeType}';
}

/// The rating where the chapter is now.
Future<String> _ratedWhereItIs(Stores s) async =>
    await s.documents.open(s.ref(_moved)) is! Opened
    ? ratedMainLine(s)
    : ratedMainLine(s, _moved);

const _moveDuringRating = Interleaving<Stores>(
  name: 'a move during a rating',
  seed: seedStandardProfile,
  open: Stores.open,
  prepare: admitMainLineRating,
  held: _rate,
  meanwhile: _move,
  read: _ratedWhereItIs,
);

Future<void> _loadBooks(Stores s) => booksOwner(s).load();

/// The book renamed by the Books owner, once its write is answered.
Future<String> _renameBook(Stores s) async {
  final books = booksOwner(s);
  books.rename(books.books.single, 'Tournament prep');
  await books.settled;
  return books.problem ?? 'saved';
}

const _booksDuringMove = Interleaving<Stores>(
  name: 'a Books edit during a relocation',
  seed: seedWithWrittenBooks,
  open: Stores.open,
  prepare: _loadBooks,
  held: _move,
  meanwhile: _renameBook,
  read: bookList,
);

void main() {
  interleavings(_reloads);
  interleavings(_moveDuringRating);
  interleavings(_booksDuringMove);
}
