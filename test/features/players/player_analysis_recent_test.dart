// A player's analysis keeps only the games of the last days when asked,
// and says its sources are current only once there is something read.
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';

String _game(String date) =>
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n'
    '[Date "$date"]\n\n1. e4 e5 1-0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScriptedDocumentStore store;
  late PlayerAnalysis analysis;

  setUp(() {
    store = ScriptedDocumentStore();
    analysis = PlayerAnalysis(
      documents: store,
      cache: GamesCache(store, folder: '/games'),
      sites: const [],
      pending: PendingWrites(),
    );
    addTearDown(analysis.dispose);
  });

  test('says nothing is current before anything is read', () async {
    expect(await analysis.currentSources(), isFalse);
  });

  test('the last days keep the recent games only', () async {
    final now = DateTime.now();
    String day(DateTime d) =>
        '${d.year}.${'${d.month}'.padLeft(2, '0')}.'
        '${'${d.day}'.padLeft(2, '0')}';
    const ref = DocumentRef('/collections/alex.pgn');
    final text = '${_game('2001.01.01')}\n\n${_game(day(now))}\n';
    store.documents[ref] = Opened(text, scriptedRevision(text));
    final alex = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await analysis.select(alex);
    expect(analysis.gameIndexes, hasLength(2));
    expect(await analysis.currentSources(), isTrue);
    analysis.recentDays = 30;
    expect(analysis.gameIndexes, hasLength(1));
  });
}
