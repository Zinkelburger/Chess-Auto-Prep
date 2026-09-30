import 'dart:async';

import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  Future<CorpusResult<CorpusSize>> size(String path) async => const CorpusRead((
    games: 1,
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
    if (filter.player.isEmpty && delayed != null) {
      if (!entered.isCompleted) entered.complete();
      return delayed!.future;
    }
    return const CorpusRead((games: [alice], more: false));
  }

  @override
  Future<CorpusResult<String>> game(String path, int id) async =>
      const CorpusRead('[White "Alice"]\n[Black "Bob"]\n\n1. e4 e5 *');

  /// Holds every import until completed.
  Completer<void>? importing;
  @override
  Future<CorpusResult<(int, int)>> importPgn(String source, String path) async {
    await importing?.future;
    return const CorpusRead((1, 0));
  }
}

void main() {
  late DatabaseLibrary library;
  late DelayedCorpus corpus;
  late ScriptedDocumentStore documents;
  setUp(() {
    corpus = DelayedCorpus();
    documents = ScriptedDocumentStore();
    library = DatabaseLibrary(
      path: '/master_games.db',
      corpus: corpus,
      picker: ScriptedPicker(),
      documents: documents,
      collections: '/collections',
      pending: PendingWrites(),
    );
  });
  tearDown(() => library.dispose());

  test('a delayed error for old filters cannot replace the new ones', () async {
    corpus.delayed = Completer();
    final reading = library.refresh();
    await corpus.entered.future;
    unawaited(library.search(const CorpusFilter(player: 'Alice')));
    corpus.delayed!.complete(const CorpusFailure('old filters failed'));
    await reading;
    expect(library.filter.player, 'Alice');
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

  group('one writer to master_games.db at a time', () {
    late ScriptedPicker picker;
    late Completer<void> answered;
    late Completer<http.Response> index;
    var clients = 0;
    DatabaseLibrary withDownload() {
      clients = 0;
      answered = Completer();
      index = Completer();
      picker = ScriptedPicker('/games.pgn');
      final download = TwicDownload(
        '/master_games.db',
        client: () {
          clients++;
          return MockClient((request) {
            if (!answered.isCompleted) answered.complete();
            return index.future;
          });
        },
      );
      return DatabaseLibrary(
        path: '/master_games.db',
        corpus: corpus,
        picker: picker,
        documents: documents,
        collections: '/collections',
        pending: PendingWrites(),
        download: download,
      );
    }

    test('a TWIC download waits for a running import', () async {
      final databases = withDownload();
      addTearDown(databases.dispose);
      corpus.importing = Completer();
      final importing = databases.importFile();
      await pumpEventQueue();
      expect(databases.busy, isTrue);
      await databases.downloadTwic(1);
      expect(clients, 0);
      expect(databases.download!.running, isFalse);
      expect(databases.message, 'Wait for the import to finish.');
      corpus.importing!.complete();
      await importing;
      expect(databases.message, 'Imported 1 games · 0 skipped.');
      expect(databases.busy, isFalse);
    });

    test('an import waits for a running TWIC download', () async {
      final databases = withDownload();
      addTearDown(databases.dispose);
      final downloading = databases.downloadTwic(1);
      await answered.future;
      expect(databases.busy, isTrue);
      await databases.importFile();
      expect(picker.startedIn, isEmpty);
      expect(databases.activity, isNot(DatabaseActivity.importing));
      index.complete(http.Response('', 503));
      await downloading;
      expect(databases.download!.problem, contains('503'));
      expect(databases.busy, isFalse);
    });
  });
}
