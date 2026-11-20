import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/pgn/collection_player.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/features/pgn_viewer/viewer_reading.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:chess_auto_prep/workspace/explorer/file_filter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/session_fixture.dart';

/// Every place saved, in order.
final class _Places implements ViewerPlaces {
  final saved = <ReadingPlace>[];

  @override
  Future<ReadingPlace?> load(String path) async => null;

  @override
  Future<void> save(String path, ReadingPlace place) async => saved.add(place);
}

void main() {
  Future<(ViewerReading, _Places, SessionFixture)> started() async {
    final fixture = await openSession(
      '[Event "One"]\n\n1. e4 e5 2. Nf3 Nc6 *\n',
    );
    addTearDown(fixture.dispose);
    // As the viewer shows a file: one game at a time.
    await fixture.session.open(fixture.ref, game: 0);
    final filter = FileFilter(fixture.session);
    addTearDown(filter.dispose);
    final places = _Places();
    final reading = ViewerReading(
      session: fixture.session,
      filter: filter,
      pending: PendingWrites(),
      store: places,
      activePath: () => fixture.ref.path,
      sort: () => GameOrder.fileOrder,
      setSort: (_) {},
      perspective: () => const FollowCollectionPlayer(),
      changed: () {},
    )..start();
    return (reading, places, fixture);
  }

  test('steps through one game are written once the cursor settles, not on '
      'every move', () async {
    final (reading, places, fixture) = await started();
    addTearDown(reading.dispose);
    reading.capture();
    await pumpEventQueue();
    places.saved.clear();
    final cursor = fixture.session.cursor;
    for (var i = 0; i < 10; i++) {
      cursor.goTo(NodePath.of(List.filled(i % 4 + 1, 0)));
    }
    await pumpEventQueue();
    expect(places.saved, isEmpty);
    expect(await reading.pending.settle(), isNull);
    expect(places.saved, hasLength(1));
    expect(places.saved.single.path, cursor.value);
  });

  test('a place still settling is written when the viewer goes away', () async {
    final (reading, places, fixture) = await started();
    reading.capture();
    await pumpEventQueue();
    places.saved.clear();
    fixture.session.cursor.goTo(NodePath.of(const [0, 0]));
    reading.dispose();
    await pumpEventQueue();
    expect(places.saved.single.path, NodePath.of(const [0, 0]));
  });

  test(
    'a late restore leaves a newer lookup alone and saves movement in the same file',
    () async {
      final text = List.generate(
        500,
        (i) => '[Event "Game $i"]\n\n1. e4 *',
      ).join('\n\n');
      final fixture = await openSession(text);
      addTearDown(fixture.dispose);
      final session = fixture.session;
      await session.open(fixture.ref, game: 0);
      final filter = FileFilter(session);
      addTearDown(filter.dispose);
      final places = _Places();
      final lookups = <Completer<int>>[];
      final reading = ViewerReading(
        session: session,
        filter: filter,
        pending: PendingWrites(),
        store: places,
        activePath: () => session.source?.path,
        sort: () => GameOrder.fileOrder,
        setSort: (_) {},
        perspective: () => const FollowCollectionPlayer(),
        changed: () {},
        locateElsewhere: (_, _) {
          final lookup = Completer<int>();
          lookups.add(lookup);
          return lookup.future;
        },
      )..start();
      addTearDown(reading.dispose);
      const place = ReadingPlace(
        game: 499,
        key: 'last',
        path: NodePath.root(),
        sort: GameOrder.fileOrder,
      );
      final first = reading.restore(place, () => session.source == fixture.ref);
      final next = chapterRef('KID', 'Next');
      fixture.store.documents[next] = Opened(text, scriptedRevision(text));
      await session.open(next, game: 0);
      final second = reading.restore(place, () => session.source == next);
      lookups.first.complete(499);
      await first;
      reading.capture();
      expect(places.saved, isEmpty);
      lookups.last.complete(499);
      await second;
      await reading.pending.settle();
      expect(places.saved, isNotEmpty);
      expect(places.saved.map((p) => p.game), everyElement(499));

      places.saved.clear();
      var current = true;
      final third = reading.restore(place, () => current);
      session.cursor.goTo(NodePath.of([0]));
      current = false; // Opening a picker overtakes the lookup even on cancel.
      lookups.last.complete(0);
      await third;
      await reading.pending.settle();
      expect(places.saved.single.game, 499);
      expect(places.saved.single.path, NodePath.of([0]));
    },
  );

  test('a place that cannot be looked for in a long file says so and leaves '
      'the file open where it opened', () async {
    // Long enough that the place is looked for off the UI isolate.
    final text = [
      for (var i = 0; i < 520; i++) '[Event "Game $i"]\n\n1. e4 e5 *\n',
    ].join('\n');
    final fixture = await openSession(text);
    addTearDown(fixture.dispose);
    final filter = FileFilter(fixture.session);
    addTearDown(filter.dispose);
    var changes = 0;
    final reading = ViewerReading(
      session: fixture.session,
      filter: filter,
      pending: PendingWrites(),
      store: null,
      activePath: () => fixture.ref.path,
      sort: () => GameOrder.fileOrder,
      setSort: (_) {},
      perspective: () => const FollowCollectionPlayer(),
      changed: () => changes++,
      locateElsewhere: (place, games) async =>
          throw StateError('Isolate exited'),
    );
    addTearDown(reading.dispose);
    final shown = fixture.session.game;

    await reading.restore(
      ReadingPlace(
        game: 300,
        key: 'k',
        path: NodePath.of(const [0]),
        sort: GameOrder.fileOrder,
      ),
      () => true,
    );

    expect(reading.problem, 'Could not find your place in this file.');
    expect(changes, greaterThan(0));
    expect(fixture.session.game, shown);
  });

  // A long file opens on its first game while its bookmark is located.
  group('a pending bookmark lookup', () {
    late SessionFixture fixture;
    late _Places places;
    late ViewerReading reading;
    late Completer<int> lookup;
    late GameOrder sort;
    late int changes;
    const place = ReadingPlace(
      game: 499,
      key: 'last',
      path: NodePath.root(),
      sort: GameOrder.fileOrder,
    );
    setUp(() async {
      final text = [
        for (var i = 0; i < 500; i++) '[Event "Game $i"]\n\n1. e4 e5 *',
      ].join('\n\n');
      fixture = await openSession(text);
      addTearDown(fixture.dispose);
      await fixture.session.open(fixture.ref, game: 0);
      final filter = FileFilter(fixture.session);
      addTearDown(filter.dispose);
      places = _Places();
      lookup = Completer<int>();
      sort = GameOrder.fileOrder;
      changes = 0;
      reading = ViewerReading(
        session: fixture.session,
        filter: filter,
        pending: PendingWrites(),
        store: places,
        activePath: () => fixture.ref.path,
        sort: () => sort,
        setSort: (value) => sort = value,
        perspective: () => const FollowCollectionPlayer(),
        changed: () => changes++,
        locateElsewhere: (_, _) => lookup.future,
      )..start();
      addTearDown(reading.dispose);
    });

    test(
      'a lookup failure after sorting preserves the bookmark and error',
      () async {
        final restoring = reading.restore(place, () => true);
        sort = GameOrder.dateDesc;
        reading.capture();
        lookup.completeError(StateError('Isolate exited'));
        await restoring;
        await reading.pending.settle();
        expect(reading.problem, 'Could not find your place in this file.');
        expect(changes, greaterThan(0));
        expect(fixture.session.game, 0);
        expect(places.saved, isEmpty);
      },
    );

    test('a place found after the viewer went away is not shown', () async {
      final restoring = reading.restore(place, () => true);
      reading.dispose();
      lookup.complete(499);
      await restoring;
      expect(fixture.session.game, 0);
    });

    test('a place found after another file was asked for is not shown', () async {
      var current = true;
      final restoring = reading.restore(place, () => current);
      current = false;
      lookup.complete(499);
      await restoring;
      expect(fixture.session.game, 0);
    });

    test('a place found after the user moved is not shown: the move stands', () async {
      final restoring = reading.restore(place, () => true);
      fixture.session.cursor.goTo(NodePath.of(const [0]));
      lookup.complete(499);
      await restoring;
      expect(fixture.session.game, 0);
      expect(fixture.session.cursor.value, NodePath.of(const [0]));
    });
  });

  test('of two restores in flight only the newer one places the file', () async {
    final text = [
      for (var i = 0; i < 500; i++) '[Event "Game $i"]\n\n1. e4 e5 *',
    ].join('\n\n');
    final fixture = await openSession(text);
    addTearDown(fixture.dispose);
    await fixture.session.open(fixture.ref, game: 0);
    final filter = FileFilter(fixture.session);
    addTearDown(filter.dispose);
    final lookups = <Completer<int>>[];
    final reading = ViewerReading(
      session: fixture.session,
      filter: filter,
      pending: PendingWrites(),
      store: _Places(),
      activePath: () => fixture.ref.path,
      sort: () => GameOrder.fileOrder,
      setSort: (_) {},
      perspective: () => const FollowCollectionPlayer(),
      changed: () {},
      locateElsewhere: (_, _) {
        final lookup = Completer<int>();
        lookups.add(lookup);
        return lookup.future;
      },
    )..start();
    addTearDown(reading.dispose);
    ReadingPlace at(int game) => ReadingPlace(
      game: game,
      key: 'k$game',
      path: const NodePath.root(),
      sort: GameOrder.fileOrder,
    );
    final older = reading.restore(at(499), () => true);
    final newer = reading.restore(at(10), () => true);
    lookups.first.complete(499);
    await older;
    expect(fixture.session.game, 0, reason: 'the older place is not shown');
    lookups.last.complete(10);
    await newer;
    expect(fixture.session.game, 10);
  });

  test('a move within edits not yet on disk is not kept as the place', () async {
    final (reading, places, fixture) = await started();
    addTearDown(reading.dispose);
    reading.capture();
    await pumpEventQueue();
    places.saved.clear();
    final session = fixture.session;
    session.holdsEdits = true;
    session.setComment(const NodePath.root(), 'Held note');
    expect(session.hasHeldEdits, isTrue);
    final moved = NodePath.of(const [0, 0]);
    session.cursor.goTo(moved);
    reading.capture();
    await reading.pending.settle();
    expect(places.saved.map((place) => place.path), isNot(contains(moved)));
  });

  test('a restored filter is judged by the games it keeps once it has '
      'filtered them, not while it is still filtering', () async {
    final (reading, _, fixture) = await started();
    addTearDown(reading.dispose);
    // A regex rule is filtered on a worker, so the filter is busy at first.
    const kept = GameFilter(
      rules: [HeaderRule(field: 'Event', rule: FilterRule.regex, value: 'On')],
    );
    await reading.restore(
      const ReadingPlace(
        game: 0,
        key: 'k',
        path: NodePath.root(),
        sort: GameOrder.fileOrder,
        filter: kept,
      ),
      () => true,
    );
    for (var i = 0; i < 500 && reading.filter.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(reading.filter.busy, isFalse);
    expect(reading.filter.applied, kept);
    expect(reading.filter.kept, 1);
    expect(fixture.session.game, 0);
  });

  test('a place that cannot be written says so', () async {
    final fixture = await openSession('[Event "One"]\n\n1. e4 e5 *\n');
    addTearDown(fixture.dispose);
    await fixture.session.open(fixture.ref, game: 0);
    final filter = FileFilter(fixture.session);
    addTearDown(filter.dispose);
    var changes = 0;
    final reading = ViewerReading(
      session: fixture.session,
      filter: filter,
      pending: PendingWrites(),
      store: _Unwritable(),
      activePath: () => fixture.ref.path,
      sort: () => GameOrder.fileOrder,
      setSort: (_) {},
      perspective: () => const FollowCollectionPlayer(),
      changed: () => changes++,
    )..start();
    addTearDown(reading.dispose);
    reading.capture();
    await reading.pending.settle();
    expect(
      reading.problem,
      'The reading position could not be kept. Move again to retry.',
    );
    expect(changes, greaterThan(0));
  });
}

/// A preferences file that refuses every write.
final class _Unwritable implements ViewerPlaces {
  @override
  Future<ReadingPlace?> load(String path) async => null;

  @override
  Future<void> save(String path, ReadingPlace place) async =>
      throw const FileSystemException('disk full');
}
