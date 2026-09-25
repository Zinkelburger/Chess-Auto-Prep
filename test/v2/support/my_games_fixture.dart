import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/chess/tactics/mining.dart';
import 'package:chess_auto_prep/v2/engines/engine.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/net/recent_games.dart';
import 'package:chess_auto_prep/v2/storage/game_store.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:dartchess/dartchess.dart' show Side;

/// A Lichess game where "Me", with Black, walks into Scholar's mate with
/// `3... Nf6??`.
const scholarsMate = '''
[Event "Rated blitz game"]
[Site "https://lichess.org/AbCd1234"]
[Date "2026.09.20"]
[White "Rival"]
[Black "Me"]
[Result "1-0"]
[UTCDate "2026.09.20"]
[UTCTime "10:00:00"]

1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0''';

/// A Chess.com game where "Me", with White, plays one move and loses
/// nothing.
const quietChesscomGame = '''
[Event "Live Chess"]
[Site "Chess.com"]
[Date "2026.09.19"]
[White "Me"]
[Black "Other"]
[Result "*"]
[Link "https://www.chess.com/game/live/111"]

1. d4 d5 *''';

/// The position before `3... Nf6`, where `3... g6` holds.
const beforeNf6 =
    'r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3';

/// The puzzle the old app writes for `3... Nf6??`, as game 6 of the set.
const scholarsMatePuzzle =
    '''
[Event "Default #6"]
[White "Rival"]
[Black "Me"]
[Date "2026.09.20"]
[Result "*"]
[FEN "$beforeNf6"]
[SetUp "1"]
[GameId "lichess_AbCd1234"]
[UserMove "Nf6"]
[MistakeType "??"]
[OpponentBestResponse "Qxf7#"]
[SolutionPv "g6 Qf3"]
[SourceMovetext "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#"]

{Nf6 +0.0 → #-1, g6 +0.0} 3... g6 *''';

/// The engine's verdicts on [scholarsMate], by position: Black's first two
/// moves are its own choice, `3... g6` is best before `3... Nf6`, and
/// after it White mates in one.
final scholarsMateLines = <String, EngineLine>{
  const Fen(
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
  ).position: _line(
    pv: ['e7e5'],
  ),
  const Fen(
    'rnbqkbnr/pppp1ppp/8/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2',
  ).position: _line(
    pv: ['b8c6'],
  ),
  const Fen(beforeNf6).position: _line(pv: ['g7g6', 'h5f3']),
  const Fen(
    'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
  ).position: _line(
    score: const MateIn(1),
    pv: ['h5f7'],
  ),
};

EngineLine _line({
  Score score = const Centipawns(0),
  List<String> pv = const [],
}) => EngineLine(multiPv: 1, depth: 15, score: score, pv: pv);

/// The puzzle [scholarsMate]'s blunder makes.
MinedPuzzle minedScholarsMate() {
  final read = readGame(scholarsMate);
  final tree = read.tree!;
  return minedFrom(
    movesBy(tree, Side.black).last,
    const Verdict(pv: ['g7g6', 'h5f3']),
    const Verdict(mate: 1, pv: ['h5f7']),
    SourceGame.of(read.tags, tree, gameIdIn(scholarsMate)),
  )!;
}

/// An engine that answers every search at once from [lines], by position;
/// a position it has no line for is level with no moves. [onSearch] runs
/// before each answer, so a test can pause in the middle. Quitting is only
/// noted: the review starts it again as if it were a new process.
final class AnsweringEngine implements Engine {
  AnsweringEngine([Map<String, EngineLine>? lines])
    : lines = lines ?? scholarsMateLines;

  final Map<String, EngineLine> lines;
  final asked = <Fen>[];
  void Function()? onSearch;
  bool quitCalled = false;
  final _exited = Completer<EngineExit>();

  @override
  String get name => 'Answering';

  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) {
    asked.add(fen);
    onSearch?.call();
    final line = lines[fen.position] ?? _line();
    return Search(lines: Stream.fromIterable([line]), stop: () async {});
  }

  @override
  Future<EngineExit> get exited => _exited.future;

  @override
  Future<void> quit() async {
    quitCalled = true;
    if (!_exited.isCompleted) _exited.complete(EngineExit.ended);
  }
}

/// A site whose answers the test writes, one per request, the last one
/// repeated.
final class ScriptedSite implements RecentGames {
  ScriptedSite(this.site, this.answers);

  @override
  final GameSite site;
  final List<GamesFetch> answers;
  final asked = <String>[];

  @override
  Future<GamesFetch> recent(String username, {required int max}) async {
    asked.add(username);
    return answers.length > 1 ? answers.removeAt(0) : answers.single;
  }
}

/// Accounts in memory.
final class MemoryAccounts implements AccountStore {
  MemoryAccounts([Map<GameSite, Account>? accounts])
    : accounts = {...?accounts};

  final Map<GameSite, Account> accounts;

  int _revision = 0;
  @override
  int get revision => _revision;
  @override
  Future<AccountsRead> snapshot() async =>
      AccountsSnapshot(accounts: accounts, revision: revision);

  @override
  Future<Map<GameSite, Account>> read() async => {...accounts};

  @override
  Future<bool> setDownloaded(GameSite site, DateTime when) async {
    final account = accounts[site];
    if (account != null) {
      accounts[site] = Account(account.username, downloaded: when);
    }
    return true;
  }

  @override
  Future<bool> setUsername(GameSite site, String? username) async {
    _revision++;
    final name = username?.trim() ?? '';
    if (name.isEmpty) {
      accounts.remove(site);
    } else if (accounts[site]?.username != name) {
      accounts[site] = Account(name);
    }
    return true;
  }
}

/// The old app's games database as the test sets it: absent until given
/// games, or answering what [answer] says. Remembers the collections each
/// read asked for.
final class ScriptedGameStore implements GameStore {
  StoredGamesRead answer = const StoredGamesAbsent();
  final asked = <Set<String>>[];

  @override
  Future<StoredGamesRead> read(Set<String> collections) async {
    asked.add(collections);
    return switch (answer) {
      StoredGamesFound(:final games, :final skipped) => StoredGamesFound([
        for (final game in games)
          if (collections.contains(game.collection)) game,
      ], skipped: skipped),
      final other => other,
    };
  }
}
