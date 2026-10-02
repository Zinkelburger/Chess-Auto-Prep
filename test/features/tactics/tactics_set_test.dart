import 'dart:async';
import 'dart:math';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_edits.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_queue.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';

/// The set over the real session and saver, with a scripted store holding
/// it.
void main() {
  test('random order stays put while each attempt is written into the '
      'set', () async {
    final store = ScriptedDocumentStore()
      ..documents[tacticsRef] = Opened(
        tacticsSet,
        scriptedRevision(tacticsSet),
      );
    final saver = DocumentSaver(store, delay: Duration.zero);
    final session = DocumentSession(store, saver);
    final settings = SettingsStore();
    final set = TacticsSet(
      documents: store,
      session: session,
      settings: settings,
      ref: tacticsRef,
      now: () => tacticsToday,
      random: Random(5),
    );
    addTearDown(() {
      set.dispose();
      session.dispose();
      saver.dispose();
      settings.dispose();
    });
    await settings.update(
      settings.value.copyWith(
        puzzles: const PuzzleFilter(
          order: PuzzleOrder.random,
          groupByGame: false,
        ),
      ),
    );
    await session.open(tacticsRef, game: 0);
    List<Fen> order() => [for (final puzzle in set.queue) puzzle.fen];
    final first = order();
    expect(first, hasLength(4));

    for (final puzzle in set.queue.toList()) {
      final refused = session.apply(
        (chapter) => recordAttempt(
          chapter,
          index: puzzle.index,
          fen: puzzle.fen,
          solved: true,
          seconds: 3,
          now: tacticsToday,
        ),
      );
      expect(refused, isNull);
      expect(order(), first);
    }
  });

  group('delete', () {
    late ScriptedDocumentStore store;
    late DocumentSaver saver;
    late DocumentSession session;
    late SettingsStore settings;
    late TacticsSet set;

    setUp(() {
      store = ScriptedDocumentStore()
        ..documents[tacticsRef] = Opened(
          tacticsSet,
          scriptedRevision(tacticsSet),
        );
      saver = DocumentSaver(store, delay: Duration.zero);
      session = DocumentSession(store, saver);
      settings = SettingsStore();
      set = TacticsSet(
        documents: store,
        session: session,
        settings: settings,
        ref: tacticsRef,
        now: () => tacticsToday,
      );
    });

    tearDown(() {
      set.dispose();
      session.dispose();
      saver.dispose();
      settings.dispose();
    });

    String onDisk() => (store.documents[tacticsRef]! as Opened).text;

    test(
      'text search is part of the queue and clearing restores its order',
      () async {
        await set.load();
        final original = set.queue.map((p) => p.index).toList();
        set.search('Rival');
        expect(set.queue, isNotEmpty);
        expect(set.queue.every((p) => p.matches('Rival')), isTrue);
        expect(set.queue.length, lessThan(original.length));
        set.search('no such opponent');
        expect(set.queue, isEmpty);
        set.search('');
        expect(set.queue.map((p) => p.index), original);
      },
    );

    test('with the set closed, the file is written without the puzzle and '
        'the list follows', () async {
      await set.load();
      final second = set.puzzles[1];
      expect(await set.delete(second), isNull);
      expect(onDisk(), isNot(contains('Default #2')));
      expect(onDisk(), startsWith('; ChessAutoPrep-Analyzed-v1:'));
      expect(set.puzzles, hasLength(4));
      expect(set.puzzles.map((p) => p.fen), isNot(contains(second.fen)));
    });

    test('with a puzzle up, the session takes it out and saves', () async {
      await session.open(tacticsRef, game: 0);
      final second = set.puzzles[1];
      expect(await set.delete(second), isNull);
      await saver.flush();
      expect(onDisk(), isNot(contains('Default #2')));
      expect(session.game, 0, reason: 'the puzzle up stays up');
    });

    test('a load that read the file before a delete landed does not bring '
        'the puzzle back', () async {
      await set.load();
      final second = set.puzzles[1];
      final gate = store.readEarly = Completer<void>();
      final loading = set.load();
      expect(await set.delete(second), isNull);
      gate.complete();
      await loading;
      expect(set.puzzles, hasLength(4));
      expect(set.puzzles.map((p) => p.fen), isNot(contains(second.fen)));
    });

    test('a puzzle already gone is said, and nothing is written', () async {
      await set.load();
      final second = set.puzzles[1];
      expect(await set.delete(second), isNull);
      expect(await set.delete(second), isNotNull);
      expect(set.puzzles, hasLength(4));
    });
  });
}
