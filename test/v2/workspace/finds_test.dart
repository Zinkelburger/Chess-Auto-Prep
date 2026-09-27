import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/finds.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/storage/finds_store.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/v2/workspace/finds.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

Fen board(String name) => Fen('$name w - - 0 1');

SearchNode leaf(String name, int cp) =>
    HorizonNode(fen: board(name), evalForUs: Eval(cp));

/// Our move at [name]: one that holds and one that loses [gap].
SearchNode onlyMoveAt(String name, int gap) => OurNode.over(
  fen: board(name),
  evalForUs: const Eval(0),
  candidates: [
    CandidateMove(
      move: const MoveRef(uci: 'a', san: 'Qd1'),
      child: leaf('$name-holds', 0),
    ),
    CandidateMove(
      move: const MoveRef(uci: 'b', san: 'Qe2'),
      child: leaf('$name-loses', -gap),
    ),
  ],
);

Find find(String name, {double worth = 1, FindKind kind = FindKind.trap}) =>
    Find(
      kind: kind,
      sans: const ['e4', 'e5'],
      ply: 2,
      keyPly: 1,
      fen: board(name),
      evalCp: 100,
      lossCp: 200,
      share: 0.3,
      reach: 0.5,
      worth: worth,
    );

void main() {
  group('the store', () {
    late FindsStore store;
    setUp(() => store = FindsStore.inMemory());
    tearDown(() => store.close());

    void keep(List<Find> finds, {Side side = Side.white, int day = 1}) =>
        store.keep(
          finds,
          side: side,
          rootFen: Fen.initial,
          elo: 1800,
          at: DateTime(2026, 9, day),
        );

    test('keeps what it is given and reads it back', () {
      keep([find('a', worth: 3)]);

      final kept = store.all().single;
      expect(kept.find.kind, FindKind.trap);
      expect(kept.find.sans, ['e4', 'e5']);
      expect(kept.find.fen.position, board('a').position);
      expect(kept.find.worth, 3);
      expect(kept.side, Side.white);
      expect(kept.rootFen, Fen.initial);
      expect(kept.elo, 1800);
      expect(kept.foundAt, DateTime(2026, 9));
    });

    test('the same place found again replaces the older find', () {
      keep([find('a', worth: 1)]);
      keep([find('a', worth: 5)], day: 2);

      final kept = store.all().single;
      expect(kept.find.worth, 5);
      expect(kept.foundAt, DateTime(2026, 9, 2));
    });

    test('another side or kind at the same place is another find', () {
      keep([find('a')]);
      keep([find('a')], side: Side.black);
      keep([find('a', kind: FindKind.onlyMove)]);

      expect(store.all(), hasLength(3));
    });

    test('removes one find', () {
      keep([find('a'), find('b')]);
      final first = store.all().first;

      store.remove(first.id);

      expect(store.all().map((k) => k.id), isNot(contains(first.id)));
    });
  });

  group('the owner', () {
    late FindsStore store;
    late Finds finds;
    setUp(() {
      store = FindsStore.inMemory();
      finds = Finds(store: () => store, clock: () => DateTime(2026, 9, 23));
    });
    tearDown(() {
      finds.dispose();
      store.close();
    });

    test('records a search from where the board stood', () async {
      finds.load();
      final tree = onlyMoveAt('root', 300);

      await finds.record(
        tree,
        rootFen: Fen.initial,
        prefix: const ['e4', 'c5'],
        side: Side.black,
        elo: 1600,
      );

      expect(finds.recorded, isA<FindsKept>());
      final kept = finds.shown.single;
      expect(kept.find.sans, ['e4', 'c5', 'Qd1']);
      expect(kept.find.ply, 2);
      expect(kept.side, Side.black);
      expect(kept.elo, 1600);
    });

    test(
      'record freezes its accepted prefix and time before awaiting',
      () async {
        var now = DateTime(2026, 9, 23);
        finds.dispose();
        finds = Finds(store: () => store, clock: () => now);
        final prefix = ['e4'];
        final recording = finds.record(
          onlyMoveAt('root', 300),
          rootFen: Fen.initial,
          prefix: prefix,
          side: Side.white,
          elo: 1800,
        );
        prefix.add('e5');
        now = DateTime(2026, 9, 24);
        await recording;
        expect(store.all().single.find.sans, ['e4', 'Qd1']);
        expect(store.all().single.foundAt, DateTime(2026, 9, 23));
      },
    );

    test('an accepted record survives owner disposal', () async {
      final recording = finds.record(
        onlyMoveAt('retained', 300),
        rootFen: Fen.initial,
        prefix: const ['e4'],
        side: Side.white,
        elo: 1800,
      );
      finds.dispose();
      finds = Finds(store: () => store);
      await recording;
      expect(store.all(), hasLength(1));
    });

    test('a failed SQLite keep is never reported as kept', () async {
      final folder = await Directory.systemTemp.createTemp('finds-failed-');
      addTearDown(() => folder.delete(recursive: true));
      await Directory(p.join(folder.path, 'finds.db')).create();
      final failed = FindsStore.open(folder);
      addTearDown(failed.close);
      finds.dispose();
      finds = Finds(store: () => failed);
      await finds.record(
        onlyMoveAt('retained', 300),
        rootFen: Fen.initial,
        prefix: const ['e4'],
        side: Side.white,
        elo: 1800,
      );
      expect(finds.recorded, isNot(isA<FindsKept>()));
    });

    test(
      'retained failed batches retry after disposal in acceptance order',
      () async {
        final folder = await Directory.systemTemp.createTemp('finds-retry-');
        addTearDown(() => folder.delete(recursive: true));
        final blocked = Directory(p.join(folder.path, 'finds.db'));
        await blocked.create();
        final disk = FindsStoreOnDemand(folder);
        addTearDown(disk.close);
        final pending = PendingWrites();
        FindsStore open() => disk.store;
        var now = DateTime(2026, 9, 23);
        finds.dispose();
        finds = Finds(store: open, pendingWrites: pending, clock: () => now);
        await finds.record(
          onlyMoveAt('root', 300),
          rootFen: Fen.initial,
          prefix: const ['e4'],
          side: Side.white,
          elo: 1800,
        );
        now = DateTime(2026, 9, 24);
        await finds.record(
          onlyMoveAt('root', 200),
          rootFen: Fen.initial,
          prefix: const ['d4'],
          side: Side.white,
          elo: 1900,
        );
        expect(await pending.settle(), contains('Search positions'));
        finds.dispose();
        finds = Finds(store: open, pendingWrites: pending);
        expect(finds.canRetry, isTrue);
        await blocked.delete();
        expect(await finds.retry(), isTrue);
        expect(await pending.settle(), isNull);
        expect(disk.store.all(), hasLength(1));
        final kept = disk.store.all().single;
        expect(kept.foundAt, DateTime(2026, 9, 24));
        expect(kept.find.sans, ['d4', 'Qd1']);
        expect(kept.elo, 1900);
        disk.close();
        expect(
          disk.store.all().single.foundAt,
          kept.foundAt,
          reason: 'committed values survive a native reopen',
        );
      },
    );

    test('orders, filters and steps through what it shows', () {
      store.keep(
        [
          find('small', worth: 1),
          find('big', worth: 9),
          find('only', worth: 5, kind: FindKind.onlyMove),
        ],
        side: Side.white,
        rootFen: Fen.initial,
        elo: 1800,
        at: DateTime(2026, 9),
      );
      finds.load();

      expect(finds.shown.map((k) => k.find.worth), [9, 5, 1]);

      finds.show(FindKind.onlyMove);
      expect(finds.shown.map((k) => k.find.kind), [FindKind.onlyMove]);
      finds.show(null);
      expect(finds.shown, hasLength(3));

      final first = finds.step(1)!;
      expect(first.find.worth, 9);
      finds.select(first.id);
      expect(finds.step(1)!.find.worth, 5);
      expect(finds.step(-1), isNull);

      finds.remove(first.id);
      expect(finds.shown.map((k) => k.find.worth), [5, 1]);
      expect(finds.selected, isNull);
    });
  });
}
