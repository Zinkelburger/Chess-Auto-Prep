import 'dart:async';
import 'dart:math';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_queue.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';

/// The set read from the file while the workspace has something else open:
/// a puzzle's own text, the day and the order the queue follows, and reads
/// and writes that cross.
void main() {
  late ScriptedDocumentStore store;
  late DocumentSaver saver;
  late DocumentSession session;
  late SettingsStore settings;
  late TacticsSet set;
  late DateTime today;
  var disposed = false;

  void build({Random? random}) {
    set = TacticsSet(
      documents: store,
      session: session,
      settings: settings,
      ref: tacticsRef,
      now: () => today,
      random: random,
    );
  }

  setUp(() {
    today = tacticsToday;
    disposed = false;
    store = ScriptedDocumentStore()
      ..documents[tacticsRef] = Opened(tacticsSet, scriptedRevision(tacticsSet));
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    settings = SettingsStore();
    build();
  });

  tearDown(() {
    if (!disposed) set.dispose();
    session.dispose();
    saver.dispose();
    settings.dispose();
  });

  void putOnDisk(String text) =>
      store.documents[tacticsRef] = Opened(text, scriptedRevision(text));

  test('a puzzle\'s own game is its text in the set, and none once the set '
      'no longer holds it there', () async {
    await set.load();
    final first = set.puzzles.first;
    expect(set.textOf(first), contains('[Event "Default #1"]'));
    expect(set.textOf(first), contains('4. Qxf7#'));

    final last = set.puzzles.last;
    expect(await set.delete(last), isNull);
    expect(set.textOf(last), isNull, reason: 'past the end of the set now');
    // The second puzzle taken out moves the third into its place.
    final second = set.puzzles[1];
    final third = set.puzzles[2];
    expect(await set.delete(second), isNull);
    expect(set.textOf(third), isNull, reason: 'another puzzle is there now');
  });

  test('the queue is worked out again when the day changes', () async {
    await settings.update(
      settings.value.copyWith(puzzles: const PuzzleFilter(days: 14)),
    );
    await set.load();
    final now = set.filteredQueue;
    expect(now.length, greaterThan(1));
    today = tacticsToday.add(const Duration(days: 60));
    final later = set.filteredQueue;
    expect(
      later.map((puzzle) => puzzle.index),
      [3],
      reason: 'only the custom puzzle, which has no date, is still recent',
    );
  });

  group('random order', () {
    List<Fen> order() => [for (final puzzle in set.queue) puzzle.fen];

    Future<void> pick(PuzzleFilter filter) async {
      await settings.update(settings.value.copyWith(puzzles: filter));
    }

    test('picking Random again asks for a new order; another filter '
        'change keeps it', () async {
      set.dispose();
      build(random: Random(3));
      final random = PuzzleFilter(
        order: PuzzleOrder.random,
        groupByGame: false,
        hideOneStar: false,
        kinds: {...MistakeKind.values},
      );
      await set.load();
      order();
      await pick(random);
      final first = order();
      expect(first, hasLength(5));

      await pick(random.copyWith(unreviewedOnly: false, hideOneStar: true));
      await pick(random);
      expect(order(), first, reason: 'still Random: the same order');

      // Asked for again, each time a new order; one of a few draws can
      // repeat by chance, never all of them.
      final orders = <String>{first.join()};
      for (var i = 0; i < 4; i++) {
        await pick(random.copyWith(order: PuzzleOrder.newest));
        order();
        await pick(random);
        orders.add(order().join());
      }
      expect(orders.length, greaterThan(1));
    });
  });

  test('a puzzle taken out while the set is being closed still goes, and '
      'the answer says so', () async {
    await set.load();
    store.hold = true;
    final deleting = set.delete(set.puzzles[1]);
    await pumpEventQueue();
    store.releaseAll();
    await pumpEventQueue();
    set.dispose();
    disposed = true;
    store
      ..hold = false
      ..releaseAll();
    expect(await deleting, isNull);
    expect(
      (store.documents[tacticsRef]! as Opened).text,
      isNot(contains('Default #2')),
    );
  });

  test('a read that came off the disk before a newer one does not replace '
      'it', () async {
    await set.load();
    final gate = store.readEarly = Completer<void>();
    final old = set.load();
    final shorter = tacticsSet.substring(
      0,
      tacticsSet.indexOf('[Event "Default #3"]'),
    );
    putOnDisk(shorter);
    await set.load();
    expect(set.puzzles, hasLength(2));
    gate.complete();
    await old;
    expect(set.puzzles, hasLength(2), reason: 'the older read is dropped');
  });

  test('a large file still being read is dropped when a newer read lands '
      'first', () async {
    // Over the size read on another isolate, so the newer, small read
    // finishes while the large one is still being parsed.
    final large = tacticsSet.replaceFirst(
      '{Qe2 +9.9',
      '{${'x' * (70 * 1024)}} {Qe2 +9.9',
    );
    putOnDisk(large);
    final old = set.load();
    await pumpEventQueue(times: 2);
    final shorter = tacticsSet.substring(
      0,
      tacticsSet.indexOf('[Event "Default #3"]'),
    );
    putOnDisk(shorter);
    await set.load();
    expect(set.puzzles, hasLength(2));
    await old;
    expect(set.puzzles, hasLength(2), reason: 'the older read is dropped');
  });
}
