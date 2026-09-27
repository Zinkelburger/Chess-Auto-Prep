// A save that removes or moves whole games says where each surviving game
// went. These are the ways a save whose words do not match that is stopped
// before it reaches the disk.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

/// The heading plus the games named, in that order, as the file holds them.
String filed(List<String> games) => chapterOf(games);

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('a save that takes out the game it named goes through', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final left = filed([gameOf(1, '1. d4'), gameOf(3, '1. c4')]);

    final saved = await fixture.store.save(
      ref,
      left,
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), left);
  });

  test('a save that also changed a game it carried over is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final before = await File(ref.path).readAsBytes();

    final refused = await fixture.store.save(
      ref,
      filed([gameOf(1, '1. d4'), gameOf(3, '1. c4 g6')]),
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
    );

    expect((refused as SaveRefused).detail, contains('game 3 would change'));
    expect(await File(ref.path).readAsBytes(), before);
  });

  test('a save that leaves a different number of games is refused', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);

    final refused = await fixture.store.save(
      ref,
      filed([gameOf(1, '1. d4')]),
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
    );

    expect((refused as SaveRefused).detail, contains('would leave 1 game'));
    expect(await File(ref.path).readAsString(), threeGames);
  });

  test('games put in another order are still their own bytes', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final moved = filed([
      gameOf(2, '1. e4'),
      gameOf(1, '1. d4'),
      gameOf(3, '1. c4'),
    ]);

    final saved = await fixture.store.save(
      ref,
      moved,
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [1, 0, 2], before: 3)),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), moved);
  });

  test('a save may not name one game of the file twice', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);

    final refused = await fixture.store.save(
      ref,
      filed([gameOf(1, '1. d4'), gameOf(1, '1. d4'), gameOf(3, '1. c4')]),
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [0, 0, 2], before: 3)),
    );

    expect((refused as SaveRefused).detail, contains('which it may not'));
    expect(await File(ref.path).readAsString(), threeGames);
  });

  test('the heading may change only when the edit says it does', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);
    final recoloured = threeGames.replaceFirst(
      '// Color: White',
      '// Color: Black',
    );

    final refused = await fixture.store.save(
      ref,
      recoloured,
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [0, 1, 2], before: 3)),
    );
    final saved = await fixture.store.save(
      ref,
      recoloured,
      expected: revision,
      scope: GamesRearranged(
        GamesArranged(order: const [0, 1, 2], before: 3, heading: true),
      ),
    );

    expect((refused as SaveRefused).detail, contains('heading would change'));
    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), recoloured);
  });

  test('a heading edit may write the side line and nothing else', () async {
    final ref = fixture.ref('KID/Main.pgn');
    final revision = await fixture.put(ref, threeGames);

    final refused = await fixture.store.save(
      ref,
      threeGames
          .replaceFirst('// Color: White', '// Color: Black')
          .replaceFirst('// Main', '// Renamed'),
      expected: revision,
      scope: GamesRearranged(
        GamesArranged(order: const [0, 1, 2], before: 3, heading: true),
      ),
    );

    expect(
      (refused as SaveRefused).detail,
      contains('beyond the playing side'),
    );
    expect(await File(ref.path).readAsString(), threeGames);
  });

  test('lines moved into a chapter that has none may start on a line of '
      'their own', () async {
    // The file ends without a line end, as a hand-made one can.
    final ref = fixture.ref('KID/Empty.pgn');
    final revision = await fixture.put(ref, '// Empty\n// Color: White');
    final text = '// Empty\n// Color: White\n\n${gameOf(1, '1. d4')}\n';

    final saved = await fixture.store.save(
      ref,
      text,
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [null], before: 0)),
    );

    expect(saved, isA<Saved>());
    expect(await File(ref.path).readAsString(), text);
  });

  test('but what the heading said may not go with it', () async {
    final ref = fixture.ref('KID/Empty.pgn');
    final revision = await fixture.put(ref, '// Empty\n// Color: White');

    final refused = await fixture.store.save(
      ref,
      '// Color: White\n\n${gameOf(1, '1. d4')}\n',
      expected: revision,
      scope: GamesRearranged(GamesArranged(order: const [null], before: 0)),
    );

    expect((refused as SaveRefused).detail, contains('heading would change'));
    expect(await File(ref.path).readAsString(), '// Empty\n// Color: White');
  });

  test(
    'the side of a file that starts with a byte-order mark may change',
    () async {
      final ref = fixture.ref('KID/Main.pgn');
      final white = '\uFEFF// Color: White\n\n${gameOf(1, '1. d4')}\n';
      await Directory(p.dirname(ref.path)).create(recursive: true);
      await File(ref.path).writeAsBytes(utf8.encode(white));
      final revision = await fixture.revisionOf(ref);

      final saved = await fixture.store.save(
        ref,
        white.replaceFirst('White', 'Black'),
        expected: revision,
        scope: GamesRearranged(
          GamesArranged(order: const [0], before: 1, heading: true),
        ),
      );

      expect(saved, isA<Saved>());
      expect((await File(ref.path).readAsBytes()).take(3), [0xEF, 0xBB, 0xBF]);
    },
  );

  group('two edits that collapse into one save', () {
    test('a removal and a move written after it name the right games', () {
      final both = scopeOfBoth(
        GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
        GamesEdited(GamesWritten(rewritten: const {1})),
      );

      final arranged = (both as GamesRearranged).arranged;
      expect(arranged.order, [0, 2]);
      expect(arranged.rewritten, {2});
      expect(arranged.before, 3);
    });

    test('a move and a removal written after it name the right games', () {
      final both = scopeOfBoth(
        GamesEdited(GamesWritten(rewritten: const {0}, appended: 1)),
        GamesRearranged(GamesArranged(order: const [1, 2, 3], before: 4)),
      );

      final arranged = (both as GamesRearranged).arranged;
      expect(arranged.order, [1, 2, null]);
      expect(arranged.rewritten, {0});
      expect(arranged.before, 3);
    });

    test('a removal and a game added after it are one arrangement', () {
      final both = scopeOfBoth(
        GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
        GamesEdited(GamesWritten(appended: 1)),
      );

      final arranged = (both as GamesRearranged).arranged;
      expect(arranged.order, [0, 2, null]);
      expect(arranged.rewritten, isEmpty);
      expect(arranged.before, 3);
    });

    test('a removal and a game written after it save as one', () async {
      final ref = fixture.ref('KID/Main.pgn');
      final revision = await fixture.put(ref, threeGames);
      // Game 2 taken out, then the second game left — the file's third —
      // written again, and a game added at the end.
      final both = scopeOfBoth(
        GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
        GamesEdited(GamesWritten(rewritten: const {1}, appended: 1)),
      );
      final text = filed([
        gameOf(1, '1. d4'),
        gameOf(3, '1. c4 e5'),
        gameOf(4, '1. Nf3'),
      ]);

      final saved = await fixture.store.save(
        ref,
        text,
        expected: revision,
        scope: both,
      );

      expect(saved, isA<Saved>());
      expect(await File(ref.path).readAsString(), text);
    });

    test('a pair that started from different versions is not composed', () {
      final both = scopeOfBoth(
        GamesRearranged(GamesArranged(order: const [0, 2], before: 3)),
        GamesRearranged(GamesArranged(order: const [0], before: 7)),
      );

      expect(both, isA<WholeDocument>());
    });

    test('a removal beside a restore covers everything, which is the whole '
        'document', () {
      final both = scopeOfBoth(
        GamesRearranged(GamesArranged(order: const [0], before: 2)),
        const RestoredVersion(),
      );

      expect(both, isA<WholeDocument>());
    });
  });
}
