import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:chess_auto_prep/v2/workspace/game_fetcher.dart';

/// What the masters database says at the start: two moves and one game.
const startAnswer = ExplorerAnswer(
  moves: [
    ExplorerMove(uci: 'e2e4', san: 'e4', white: 100, draws: 50, black: 30),
    ExplorerMove(uci: 'd2d4', san: 'd4', white: 60, draws: 40, black: 20),
  ],
  games: [
    ExplorerGame(
      id: 'abcd1234',
      white: 'Carlsen, M',
      black: 'Nakamura, H',
      whiteElo: 2830,
      blackElo: 2780,
      result: '1-0',
      year: 2024,
    ),
  ],
);

/// After 1. e4: one reply.
const afterE4Answer = ExplorerAnswer(
  moves: [
    ExplorerMove(uci: 'e7e5', san: 'e5', white: 10, draws: 10, black: 10),
  ],
);

/// A Lichess explorer whose answers the test writes, remembering what it
/// was asked. It never reaches the network.
final class ScriptedExplorerApi implements LichessExplorer {
  ScriptedExplorerApi({ExplorerFetch Function(ExplorerQuery)? answer})
    : answer = answer ?? ((_) => const ExplorerFetched(startAnswer));

  ExplorerFetch Function(ExplorerQuery) answer;

  /// Thrown by the next fetch instead of answering it.
  Object? throwing;

  /// What a game fetch answers; null fails it.
  String? pgn = '[Event "Scripted"]\n\n1. e4 e5 1-0\n';

  final asked = <ExplorerQuery>[];
  final gamesAsked = <(String, bool)>[];

  @override
  Future<ExplorerFetch> fetch(ExplorerQuery query) async {
    asked.add(query);
    if (throwing case final error?) throw error;
    return answer(query);
  }

  @override
  Future<String?> gamePgn(String id, {required bool masters}) async {
    gamesAsked.add((id, masters));
    return pgn;
  }
}

/// A master book the test fills, or leaves absent.
final class ScriptedBook implements MasterBook {
  ScriptedBook({this.present = false, BookLookup Function(Fen, bool)? answer})
    : answer = answer ?? ((_, _) => const BookFound(startAnswer));

  bool present;
  BookLookup Function(Fen, bool) answer;
  String? pgn = '[Event "TWIC"]\n\n1. d4 d5 1/2-1/2\n';
  final asked = <(Fen, bool)>[];
  final gamesAsked = <String>[];

  @override
  Future<bool> available() async => present;

  @override
  Future<BookLookup> lookup(Fen fen, {required bool classicalOnly}) async {
    asked.add((fen, classicalOnly));
    return answer(fen, classicalOnly);
  }

  @override
  Future<String?> gamePgn(String id) async {
    gamesAsked.add(id);
    return pgn;
  }
}

/// Where fetched games are kept in these tests.
const explorerCollections = '/Documents/pgn_collections';

/// An explorer over [session] that answers as soon as the event queue
/// turns: no rest before asking, so a test pumps once and looks.
Explorer explorerOver(
  DocumentSession session, {
  required SettingsStore settings,
  ScriptedExplorerApi? lichess,
  ScriptedBook? book,
  Duration debounce = Duration.zero,
}) => Explorer(
  session: session,
  settings: settings,
  databases: ExplorerDatabases(
    lichess: lichess ?? ScriptedExplorerApi(),
    book: book ?? ScriptedBook(),
  ),
  debounce: debounce,
);

/// A game fetcher over [documents] that keeps games under
/// [explorerCollections].
GameFetcher gamesOver(
  PgnDocumentStore documents, {
  ScriptedExplorerApi? lichess,
  ScriptedBook? book,
}) => GameFetcher(
  databases: ExplorerDatabases(
    lichess: lichess ?? ScriptedExplorerApi(),
    book: book ?? ScriptedBook(),
  ),
  documents: documents,
  collections: explorerCollections,
);
