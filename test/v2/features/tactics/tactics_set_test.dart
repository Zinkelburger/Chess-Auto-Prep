import 'dart:math';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_edits.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_queue.dart';
import 'package:chess_auto_prep/v2/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
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
          solved: true,
          seconds: 3,
          now: tacticsToday,
        ),
      );
      expect(refused, isNull);
      expect(order(), first);
    }
  });
}
