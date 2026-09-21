// A save that removes or moves whole games says where each surviving game
// went. These are the ways a save whose words do not match that is stopped
// before it reaches the disk.
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

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
