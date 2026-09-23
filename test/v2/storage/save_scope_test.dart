// What a save is allowed to change. A chapter holds games the edit never
// looked at, and these are the ways a save that would have touched one of
// them is stopped before it reaches the disk.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('a save that changes only the game it declared goes through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);

    final saved = await fixture.store.save(
      ref,
      firstGameEdited,
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), firstGameEdited);
  });

  test('a save that would also change a game nobody edited is refused and '
      'the file is byte for byte as it was', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final before = await File(ref.path).readAsBytes();
    // What a writer with a bug produces: the edit was to the first game and
    // the third one came out different anyway.
    final text = chapterOf([
      gameOf(1, '1. d4 Nf6'),
      gameOf(2, '1. e4'),
      gameOf(3, '1. c4 g6'),
    ]);

    final result = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect((result as SaveRefused).detail, contains('game 3 would change'));
    expect(result.detail, contains('the edit was to game 1'));
    expect(await File(ref.path).readAsBytes(), before);
    expect(fixture.keptTexts(ref), isEmpty, reason: 'nothing was replaced');
  });

  test('a writer that rewrites a game the edit never touched is refused, '
      'whatever the text says', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final before = await File(ref.path).readAsBytes();
    // A real edit: a move at the end of the first line, which writes that
    // game and says so. The scope is the edit's own answer, so a writer that
    // does more than the edit asked for cannot widen it.
    final chapter = parseChapter(name: 'Main', text: threeGames);
    final edit =
        addMove(chapter, at: NodePath.of([0]), uci: 'g8f6') as MoveAdded;
    expect(edit.written.rewritten, {0});
    final damaged = writeChapter(
      edit.chapter,
    ).replaceFirst('1. c4 *', '1. c4 e5 *');

    final result = await fixture.store.save(
      ref,
      damaged,
      expected: revision,
      scope: GamesEdited(edit.written),
    );

    expect((result as SaveRefused).detail, contains('game 3 would change'));
    expect(await File(ref.path).readAsBytes(), before);
    expect(fixture.keptTexts(ref), isEmpty);
  });

  test('a save that would drop a game is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final before = await File(ref.path).readAsBytes();
    final text = chapterOf([gameOf(1, '1. d4 Nf6'), gameOf(3, '1. c4')]);

    final result = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect((result as SaveRefused).detail, contains('game 2 would change'));
    expect(await File(ref.path).readAsBytes(), before);
    expect(fixture.keptTexts(ref), isEmpty);
  });

  test('a save that adds a game at the end and says so goes through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final text = chapterOf([
      gameOf(1, '1. d4'),
      gameOf(2, '1. e4'),
      gameOf(3, '1. c4'),
      gameOf(4, '1. Nf3'),
    ]);

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: GamesEdited(GamesWritten(appended: 1)),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
  });

  test('the first game of a chapter that had none may push the heading '
      'down', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, '// Main\n// Color: White\n');
    final text = '// Main\n// Color: White\n\n${gameOf(1, '1. d4')}\n';

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: GamesEdited(GamesWritten(appended: 1)),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
  });

  test('a save that would rewrite the heading is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final before = await File(ref.path).readAsBytes();
    final text = threeGames.replaceFirst('Color: White', 'Color: Black');

    final result = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect((result as SaveRefused).detail, contains('chapter heading'));
    expect(await File(ref.path).readAsBytes(), before);
  });

  test('a save that says it replaced the whole document goes through and is '
      'logged', () async {
    final entries = loggedFromNow();
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final text = chapterOf([gameOf(9, '1. f4')]);

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: const WholeDocument(),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
    expect(
      entries
          .where((entry) => entry.level == LogLevel.warning)
          .map((entry) => '${entry.error}'),
      contains(contains('did not say which game')),
    );
  });

  test('a compressed chapter is refused before any of this', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final compressed = gzip.encode(utf8.encode(threeGames));
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(compressed);
    final revision = await fixture.revisionOf(ref);

    final result = await fixture.store.save(
      ref,
      chapterOf([gameOf(1, '1. d4 Nf6')]),
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect((result as IoFailure).detail, contains('compressed'));
    expect(await File(ref.path).readAsBytes(), compressed);
  });

  test('a file with a byte the app cannot read opens to read only', () async {
    final ref = fixture.ref('KID/Main.pgn');
    // A stray byte among good UTF-8 in the third game: the file reads with
    // that byte as U+FFFD, and writing the reading back would put EF BF BD
    // where it was. Nothing about it may be written.
    final stray = [
      ...utf8.encode(chapterOf([gameOf(1, '1. d4'), gameOf(2, '1. e4')])),
      ...utf8.encode('[Event "Line 3"]\n[Result "*"]\n\n1. c4 {’’’’’’’’'),
      0x9d,
      ...utf8.encode('} *\n\n'),
    ];
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(stray);
    final revision = await fixture.revisionOf(ref);
    final opened = await fixture.store.open(ref) as Opened;
    expect(opened.text, contains('\uFFFD'), reason: 'the reading is lossy');
    expect(opened.readOnly, contains('not UTF-8'));

    final saved = await fixture.store.save(
      ref,
      opened.text.replaceFirst('1. d4 *', '1. d4 Nf6 *'),
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect(saved, isA<NotWritable>());
    expect(await File(ref.path).readAsBytes(), stray);
  });

  test(
    'a file with a byte-order mark keeps it through a scoped save',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final text =
          '\uFEFF${chapterOf([gameOf(1, '1. d4'), gameOf(2, '1. e4')])}';
      await Directory(p.dirname(ref.path)).create(recursive: true);
      await File(ref.path).writeAsBytes(utf8.encode(text));
      final revision = await fixture.revisionOf(ref);
      final opened = await fixture.store.open(ref) as Opened;
      expect(opened.text, startsWith('\uFEFF'));
      expect(opened.readOnly, isNull);

      final saved = await fixture.store.save(
        ref,
        opened.text.replaceFirst('1. d4 *', '1. d4 Nf6 *'),
        expected: revision,
        scope: GamesEdited(GamesWritten(rewritten: {0})),
      );

      expect(saved, isA<Saved>());
      expect((await File(ref.path).readAsBytes()).take(3), [0xEF, 0xBB, 0xBF]);
      expect(await File(ref.path).readAsString(), contains('1. d4 Nf6 *'));
    },
  );

  test('a byte-order mark right before the first game is the file\'s, and '
      'every game can still be edited', () async {
    // No heading: the mark is followed at once by the first `[Event`, which
    // the reader, taking the mark as blank, reads as the first game.
    final ref = fixture.ref('KID/Main.pgn');
    final text = '\uFEFF${gameOf(1, '1. d4')}\n\n${gameOf(2, '1. e4')}\n';
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(utf8.encode(text));
    final revision = await fixture.revisionOf(ref);
    final opened = await fixture.store.open(ref) as Opened;
    expect(opened.readOnly, isNull);

    final first = await fixture.store.save(
      ref,
      opened.text.replaceFirst('1. d4 *', '1. d4 Nf6 *'),
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );
    expect(first, isA<Saved>());
    final second = await fixture.store.save(
      ref,
      opened.text
          .replaceFirst('1. d4 *', '1. d4 Nf6 *')
          .replaceFirst('1. e4 *', '1. e4 e5 *'),
      expected: (first as Saved).receipt.committed,
      scope: GamesEdited(GamesWritten(rewritten: {1})),
    );

    expect(second, isA<Saved>());
    final bytes = await File(ref.path).readAsBytes();
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytes), contains('1. e4 e5 *'));
  });

  test('two byte-order marks stay two', () async {
    // The decoder eats one, so one goes back on; a file written with two is
    // a file with two, and giving one back would leave every scoped save
    // three bytes short of the heading it is replacing.
    final ref = fixture.ref('KID/Main.pgn');
    final text = '\uFEFF\uFEFF${chapterOf([gameOf(1, '1. d4')])}';
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(utf8.encode(text));
    final revision = await fixture.revisionOf(ref);
    final opened = await fixture.store.open(ref) as Opened;
    expect(opened.text, text);

    final saved = await fixture.store.save(
      ref,
      opened.text.replaceFirst('1. d4 *', '1. d4 Nf6 *'),
      expected: revision,
      scope: GamesEdited(GamesWritten(rewritten: {0})),
    );

    expect(saved, isA<Saved>());
    expect((await File(ref.path).readAsBytes()).take(6), [
      0xEF,
      0xBB,
      0xBF,
      0xEF,
      0xBB,
      0xBF,
    ]);
  });

  test('a byte-order mark comes through a whole-document save too', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final text = '\uFEFF${chapterOf([gameOf(1, '1. d4')])}';
    await Directory(p.dirname(ref.path)).create(recursive: true);
    await File(ref.path).writeAsBytes(utf8.encode(text));
    final revision = await fixture.revisionOf(ref);
    final opened = await fixture.store.open(ref) as Opened;

    final saved = await fixture.store.save(
      ref,
      '${opened.text}\n',
      expected: revision,
      scope: const WholeDocument(),
    );

    expect(saved, isA<Saved>());
    expect((await File(ref.path).readAsBytes()).take(3), [0xEF, 0xBB, 0xBF]);
  });

  // Putting a kept version back is a save like any other, with one more
  // check: the bytes have to be a version this store kept for this document.
  test(
    'a restored version goes back when the archive kept those bytes',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final first = await fixture.put(ref, threeGames);
      final saved = await fixture.edit(ref, firstGameEdited, first) as Saved;

      final back = await fixture.restore(
        ref,
        threeGames,
        saved.receipt.committed,
      );

      expect(back, isA<Saved>());
      expect(await File(ref.path).readAsString(), threeGames);
    },
  );

  test('a restored version is not logged as a guess', () async {
    final entries = loggedFromNow();
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final saved = await fixture.edit(ref, firstGameEdited, revision) as Saved;

    final undone = await fixture.restore(
      ref,
      saved.receipt.before,
      saved.receipt.committed,
    );

    expect(undone, isA<Saved>());
    expect(await File(ref.path).readAsString(), threeGames);
    expect(
      entries.map((entry) => '${entry.error}'),
      isNot(contains(contains('did not say which game'))),
    );
  });

  test('a restore of bytes nothing kept is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);

    final made = await fixture.restore(
      ref,
      chapterOf([gameOf(1, '1. d4 Nf6 2. c4 g6')]),
      revision,
    );

    expect((made as RestoreRefused).detail, contains('kept for this document'));
    expect(await File(ref.path).readAsString(), threeGames);
  });

  test('a scope that says games were taken out cannot be made', () {
    expect(
      () => GamesWritten(appended: -2),
      throwsA(isA<AssertionError>()),
      reason: 'no edit removes a game, so no save may declare it',
    );
  });
}
