import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/book/repertoire_shelf.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

const _path = '/repertoires/Open games/Course.pgn';

/// One course file of two chapters by tag: the Italian, two lines after
/// 3.Bc4, and the Ruy, three lines after 3.Bb5.
const course = '''
// Color: White

[Event "Italian"]
[ChapterName "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 *

[Event "Italian"]
[ChapterName "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d3 *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 f5 4. Nc3 *
''';

/// After 1.e4 e5 2.Nf3 Nc6.
const afterNc6 =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

void main() {
  final italian = ChapterRef.at(_path, section: 'Italian');
  final ruy = ChapterRef.at(_path, section: 'Ruy');
  late ScriptedDocumentStore store;
  late ScriptedFiles files;
  late RepertoireShelf shelf;

  void write(String text) => store.documents[const DocumentRef(_path)] = Opened(
    text,
    scriptedRevision(text),
  );

  setUp(() {
    store = ScriptedDocumentStore();
    write(course);
    files = ScriptedFiles(
      listing: Repertoires([
        RepertoireFolder(
          name: 'Open games',
          path: '/repertoires/Open games',
          modified: DateTime(2026),
          chapters: [italian, ruy],
        ),
      ]),
    );
    shelf = RepertoireShelf(files: files, documents: store);
  });

  /// What [chapter] plays after 1.e4 e5 2.Nf3 Nc6, and how many lines.
  Map<String, int> linesAt(ChapterRef chapter) {
    final index = shelf.indexOf(chapter)!;
    final moves = index.movesAt(const Fen(afterNc6).position)!;
    return {
      for (final MapEntry(:key, :value) in moves.entries) key: value.lines,
    };
  }

  test('failure retains the last complete index as stale', () async {
    await shelf.read(gone: () => false);
    final previous = shelf.indexOf(italian);
    files.listing = const RepertoiresUnreadable('permission denied');
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.refs, [italian, ruy]);
    expect(shelf.indexOf(italian), same(previous));
    expect(shelf.stale, isTrue);
  });

  test('an unreadable chapter is left out and the rest are indexed', () async {
    await shelf.read(gone: () => false);
    store.documents[const DocumentRef(_path)] = const Unreadable('blocked');
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.stale, isFalse);
    expect(shelf.indexOf(italian), isNull);
  });

  test('cancellation during the final document read cannot publish', () async {
    store.hold = true;
    var canceled = false;
    final reading = shelf.read(gone: () => canceled);
    await pumpEventQueue();
    expect(store.waiting, 1);
    canceled = true;
    store.releaseAll();
    await reading;
    expect(shelf.refs, isEmpty);
    expect(shelf.stale, isTrue);
  });

  test('a file parsed by a read that was overtaken is not parsed again by '
      'the next one', () async {
    store.hold = true;
    var overtaken = false;
    final first = shelf.read(gone: () => overtaken);
    await pumpEventQueue();
    expect(store.waiting, 1);
    overtaken = true;
    store
      ..hold = false
      ..releaseAll();
    await first;
    expect(shelf.refs, isEmpty);
    // Same revision, other bytes: only a fresh parse could see them.
    store.documents[const DocumentRef(_path)] = Opened(
      course.replaceFirst('3. Bc4 Nf6 4. d3', '3. d4 exd4 4. Nxd4'),
      scriptedRevision(course),
    );
    await shelf.read(gone: () => false);
    expect(shelf.stale, isFalse);
    expect(linesAt(italian), {'f1c4': 2});
    expect(linesAt(ruy), {'f1b5': 3});
  });

  test('each chapter of a course file is indexed from its own games', () async {
    await shelf.read(gone: () => false);
    expect(shelf.refs, [italian, ruy]);
    expect(linesAt(italian), {'f1c4': 2});
    expect(linesAt(ruy), {'f1b5': 3});
  });

  test('a file whose bytes are the same keeps its index; a changed one is '
      'indexed again', () async {
    await shelf.read(gone: () => false);
    final before = shelf.indexOf(ruy);
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.indexOf(ruy), same(before));
    write(course.replaceFirst('3. Bb5 f5 4. Nc3', '3. Bb5 f5 4. d3'));
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.indexOf(ruy), isNot(same(before)));
    expect(linesAt(ruy), {'f1b5': 3});
  });

  test('a read its caller gave up leaves the files to be read again by the '
      'next reader', () async {
    files.hold = true;
    var overtaken = false;
    final first = shelf.read(gone: () => overtaken);
    await pumpEventQueue();
    final second = shelf.read(gone: () => false);
    overtaken = true;
    files
      ..hold = false
      ..releaseAll();
    await first;
    expect(shelf.stale, isTrue);
    await second;
    expect(shelf.stale, isFalse);
    expect(shelf.refs, [italian, ruy]);
    expect(linesAt(ruy), {'f1b5': 3});
  });

  test('forgetting the files says so to whoever listens', () {
    var heard = 0;
    shelf.addListener(() => heard++);
    shelf.forget();
    expect(heard, 1);
    expect(shelf.stale, isTrue);
  });

  test('a read that ends says so to whoever listens', () async {
    var heard = 0;
    shelf.addListener(() => heard++);
    await shelf.read(gone: () => false);
    expect(heard, 1);
    expect(shelf.stale, isFalse);
  });

  test('a closed shelf is never fresh and reads nothing', () async {
    shelf.dispose();
    expect(shelf.stale, isTrue);
    await shelf.read(gone: () => false);
    expect(files.listings, 0);
    expect(shelf.refs, isEmpty);
    shelf.forget();
  });

  group('a listing taken before the files changed', () {
    late _ListedAtStart listed;
    late RepertoireShelf watched;
    setUp(() {
      listed = _ListedAtStart(const Repertoires([]));
      watched = RepertoireShelf(files: listed, documents: store);
      addTearDown(watched.dispose);
    });

    test('is read again, not believed', () async {
      final gate = listed.gate = Completer<void>();
      final reading = watched.read(gone: () => false);
      await pumpEventQueue();
      listed
        ..gate = null
        ..listing = files.listing;
      watched.forget();
      gate.complete();
      await reading;
      expect(watched.refs, [italian, ruy]);
      expect(watched.stale, isFalse);
    });

    test('that failed is read again, not reported', () async {
      listed.failing = true;
      final gate = listed.gate = Completer<void>();
      final reading = watched.read(gone: () => false);
      await pumpEventQueue();
      listed
        ..gate = null
        ..failing = false
        ..listing = files.listing;
      watched.forget();
      gate.complete();
      await reading;
      expect(watched.problem, isNull);
      expect(watched.refs, [italian, ruy]);
    });
  });
}

/// Files listed as they stood when the listing began, as a real folder
/// listing is, answering when [gate] opens. The shelf only lists.
final class _ListedAtStart implements ChapterFiles {
  _ListedAtStart(this.listing);

  RepertoireListing listing;
  Completer<void>? gate;

  /// Whether a listing begun now throws, as one cut off by the disk does.
  bool failing = false;

  @override
  Future<RepertoireListing> list() async {
    final seen = listing;
    final fails = failing;
    await gate?.future;
    if (fails) throw const FileSystemException('busy');
    return seen;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
