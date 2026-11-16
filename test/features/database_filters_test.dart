import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/databases_screen.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

CorpusGame _game(int id, String white) => (
  id: id,
  white: white,
  black: 'Bob',
  event: 'Club',
  date: '2026.09.27',
  eco: 'C20',
  result: '1-0',
  whiteElo: 2400,
  blackElo: 2300,
);

/// Answers every search from two games, filtered by player as typed.
final class _Corpus implements MasterCorpus {
  final searched = <CorpusFilter>[];

  @override
  Future<CorpusResult<CorpusSize>> size(String path) async => const CorpusRead((
    games: 2,
    bytes: 100,
    firstDate: '2026.09.27',
    lastDate: '2026.09.27',
    firstIssue: 0,
    lastIssue: 0,
    imports: 0,
  ));

  @override
  Future<CorpusResult<CorpusPage>> search(
    String path,
    CorpusFilter filter,
  ) async {
    searched.add(filter);
    return CorpusRead((
      games: [
        for (final game in [_game(1, 'Alice'), _game(2, 'Carol')])
          if (game.white.contains(filter.player)) game,
      ],
      more: false,
    ));
  }

  @override
  Future<CorpusResult<String>> game(String path, int id) async =>
      const CorpusRead('1. e4 *');

  @override
  Future<CorpusResult<(int, int)>> importPgn(
    String source,
    String path,
  ) async => const CorpusRead((5, 0));
}

void main() {
  testWidgets('the filter fields say what the list shows after an import', (
    tester,
  ) async {
    final corpus = _Corpus();
    final library = DatabaseLibrary(
      path: '/master_games.db',
      corpus: corpus,
      picker: ScriptedPicker('/games.pgn'),
      documents: ScriptedDocumentStore(),
      collections: '/collections',
      pending: PendingWrites(),
    );
    addTearDown(library.dispose);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabasesScreen(library: library, onOpen: (_) {}),
        ),
      ),
    );
    await tester.runAsync(library.refresh);
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('Player')), 'Alice');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Alice — Bob'), findsOneWidget);
    expect(find.text('Carol — Bob'), findsNothing);

    await tester.tap(find.text('Import PGN…'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final shown = tester
        .widget<TextField>(find.byKey(const ValueKey('Player')))
        .controller!
        .text;
    expect(library.message, 'Imported 5 games · 0 skipped.');
    expect(shown, library.filter.player);
    final listed = find.text('Carol — Bob').evaluate().isNotEmpty;
    expect(listed, shown.isEmpty);
  });
}
