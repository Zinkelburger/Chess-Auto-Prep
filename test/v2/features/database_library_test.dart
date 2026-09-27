import 'dart:async';

import 'package:chess_auto_prep/v2/features/databases/database_library.dart';
import 'package:chess_auto_prep/v2/storage/master_corpus.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

const alice = (
  id: 1,
  white: 'Alice',
  black: 'Bob',
  event: 'Club',
  date: '2026.09.27',
  eco: 'C20',
  result: '1-0',
  whiteElo: 2400,
  blackElo: 2300,
);

class DelayedCorpus implements MasterCorpus {
  Completer<CorpusResult<CorpusPage>>? delayed;
  final entered = Completer<void>();
  @override
  Future<CorpusResult<CorpusSize>> size(String path) async =>
      const CorpusRead((games: 1, bytes: 100));
  @override
  Future<CorpusResult<CorpusPage>> search(
    String path,
    CorpusFilter filter,
  ) async {
    if (path == '/a' && delayed != null) {
      if (!entered.isCompleted) entered.complete();
      return delayed!.future;
    }
    return const CorpusRead((games: [alice], more: false));
  }

  @override
  Future<CorpusResult<String>> game(String path, int id) async =>
      const CorpusRead('[White "Alice"]\n[Black "Bob"]\n\n1. e4 e5 *');
  @override
  Future<CorpusResult<(int, int)>> importPgn(
    String source,
    String cache,
  ) async => const CorpusRead((1, 0));
}

void main() {
  late DatabaseLibrary library;
  late DelayedCorpus corpus;
  late ScriptedDocumentStore documents;
  setUp(() {
    corpus = DelayedCorpus();
    documents = ScriptedDocumentStore();
    library = DatabaseLibrary(
      sources: {'A': '/a', 'B': '/b'},
      corpus: corpus,
      picker: ScriptedPicker(),
      documents: documents,
      collections: '/collections',
      pending: PendingWrites(),
    );
  });
  tearDown(() => library.dispose());

  test('a delayed old-source error cannot replace the new selection', () async {
    corpus.delayed = Completer();
    final reading = library.refresh();
    await corpus.entered.future;
    library.select('B');
    corpus.delayed!.complete(const CorpusFailure('old source failed'));
    await reading;
    expect(library.source, 'B');
    expect(library.page.games.single.white, 'Alice');
    expect(library.problem, isNull);
    expect(library.activity, DatabaseActivity.idle);
  });

  test(
    'opening the same game reuses its document instead of duplicating',
    () async {
      final first = await library.keep(alice);
      final again = await library.keep(alice);
      expect(first, isNotNull);
      expect(again, first);
      expect(documents.documents.length, 1);
      expect(library.opening, isNull);
    },
  );
}
