// The Books owner (lib/workspace/books.dart) edited twice, the second
// edit made once the first one's write was answered, with an I/O error or
// a lost answer at each effect of those writes. Its PendingWrites must
// report a problem exactly while an edit is not in books.json; an edit made
// after a failed write must carry the first one with it, never drop it; and
// the retry the Books screen offers must leave both, once. See
// owner_faults.dart.
@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/workspace/books.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/faulty_disk/owner_faults.dart';
import '../../support/faulty_disk/standard_commands.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/profile.dart';
import '../../support/profile/standard_profile.dart';

/// The Books owner of one session, on the store's books file and gate.
final class _Owned {
  _Owned(this.stores, this.pending)
    : books = Books(
        store: stores.documents.books,
        root: stores.profile.repertoires,
        pendingWrites: pending,
      );

  final Stores stores;
  final PendingWrites pending;
  final Books books;
}

_Owned _open(Profile profile) => _Owned(Stores.open(profile), PendingWrites());

Future<void> _load(_Owned s) => s.books.load();

/// The book renamed, then, once that write was answered, all of KID put in
/// it: what the owner shows afterwards.
Future<String> _edit(_Owned s) async {
  final books = s.books;
  books.rename(books.books.single, 'Tournament prep');
  await books.settled;
  final kid = RepertoireFolder(
    name: 'KID',
    path: s.stores.profile.document('repertoires/KID'),
    modified: DateTime.utc(2026, 9, 29),
    chapters: const [],
  );
  books.setRepertoire(books.books.single, kid, true);
  await books.settled;
  return books.problem ?? 'saved';
}

Future<void> _retry(_Owned s) => s.books.retry();

PendingWrites _pending(_Owned s) => s.pending;

/// The books as books.json holds them.
Future<String> _landed(Profile profile) async =>
    describeBooks(BookList.decode(await File(profile.books).readAsString()));

const _twoEdits = OwnerSequence<_Owned>(
  name: 'edit a book twice',
  seed: seedWithWrittenBooks,
  open: _open,
  prepare: _load,
  run: _edit,
  pending: _pending,
  retry: _retry,
  landed: _landed,
);

void main() => ownerFaults(_twoEdits);
