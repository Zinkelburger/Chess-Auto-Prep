import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
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

  test('an unreadable member never becomes a fresh partial index', () async {
    await shelf.read(gone: () => false);
    final previous = shelf.indexOf(italian);
    store.documents[const DocumentRef(_path)] = const Unreadable('blocked');
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.indexOf(italian), same(previous));
    expect(shelf.stale, isTrue);
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

  test('cancellation during final validation cannot publish', () async {
    final checking = Completer<void>();
    final release = Completer<RepertoireValidation>();
    files.validateWith = (_, _) {
      checking.complete();
      return release.future;
    };
    var canceled = false;
    final reading = shelf.read(gone: () => canceled);
    await checking.future;
    canceled = true;
    release.complete(const RepertoireCurrent());
    await reading;
    expect(shelf.refs, isEmpty);
    expect(shelf.version, 0);
    expect(shelf.stale, isTrue);
  });

  test(
    'invalidation during validation rejects the old result and rebuilds',
    () async {
      final checking = Completer<void>();
      final release = Completer<RepertoireValidation>();
      var validations = 0;
      files.validateWith = (_, _) async {
        validations++;
        if (validations == 1) {
          checking.complete();
          return release.future;
        }
        return const RepertoireCurrent();
      };
      final reading = shelf.read(gone: () => false);
      await checking.future;
      write(course.replaceFirst('3. Bb5 f5 4. Nc3', '3. Bb5 f5 4. d3'));
      shelf.forget();
      release.complete(const RepertoireCurrent());
      await reading;
      expect(validations, 2);
      expect(shelf.version, 1);
      expect(shelf.stale, isFalse);
    },
  );

  test(
    'a failed validation retains a usable old index until explicit retry',
    () async {
      await shelf.read(gone: () => false);
      final previous = shelf.indexOf(italian);
      files.validateWith = (_, _) async =>
          const RepertoireValidationFailed('blocked');
      shelf.forget();
      await shelf.read(gone: () => false);
      expect(shelf.version, 1);
      expect(shelf.problem, contains('blocked'));
      expect(shelf.indexOf(italian), same(previous));
      files.validateWith = null;
      await shelf.read(gone: () => false);
      expect(shelf.version, 2);
      expect(shelf.stale, isFalse);
      expect(shelf.problem, isNull);
    },
  );

  test('a newer shelf cannot validate work derived from old indexes', () async {
    await shelf.read(gone: () => false);
    final before = shelf.version;
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(await shelf.validate(version: before), isA<RepertoireChanged>());
    expect(
      await shelf.validate(version: shelf.version),
      isA<RepertoireCurrent>(),
    );
  });

  test('shelf validation checks invalidation after its final await', () async {
    await shelf.read(gone: () => false);
    final checking = Completer<void>();
    final release = Completer<RepertoireValidation>();
    files.validateWith = (_, _) {
      checking.complete();
      return release.future;
    };
    final validating = shelf.validate(
      version: shelf.version,
      additional: const {'/games/site.pgn': null},
    );
    await checking.future;
    shelf.forget();
    release.complete(const RepertoireCurrent());
    expect(await validating, isA<RepertoireChanged>());
    expect(files.additionalValidations.last, {'/games/site.pgn': null});
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
}
