import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tactics/mining.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:path/path.dart' as p;

import 'scripted_store.dart';
import 'tactics_fixture.dart';

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

/// The stored puzzle text for `3... Nf6??`, as game 6 of the set.
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
  int quitCalls = 0;
  Object? quitError;
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
    quitCalls++;
    if (!_exited.isCompleted) _exited.complete(EngineExit.ended);
    if (quitError case final error?) throw error;
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
  Object? error;

  @override
  Future<GamesFetch> recent(String username, {required int max}) async {
    asked.add(username);
    if (error case final failure?) throw failure;
    return answers.length > 1 ? answers.removeAt(0) : answers.single;
  }
}

/// Accounts in memory.
final class MemoryAccounts implements AccountStore {
  MemoryAccounts([Map<GameSite, Account>? accounts])
    : accounts = {...?accounts};

  final Map<GameSite, Account> accounts;
  bool rejectDownloaded = false;
  bool rejectUsernames = false;
  bool unavailable = false;
  void Function()? onDownloaded;

  int _revision = 0;
  @override
  int get revision => _revision;

  /// How many times the accounts were read whole.
  int snapshots = 0;

  @override
  Future<AccountsRead> snapshot() async {
    snapshots++;
    return unavailable
        ? const AccountsUnavailable('Account file could not be read.')
        : AccountsSnapshot(accounts: accounts, revision: revision);
  }

  @override
  Future<Map<GameSite, Account>> read() async =>
      unavailable ? {} : {...accounts};

  @override
  Future<bool> setDownloaded(
    GameSite site,
    DateTime when, {
    String? expectedUsername,
  }) async {
    if (rejectDownloaded) return false;
    final account = accounts[site];
    if (expectedUsername != null && account?.username != expectedUsername) {
      return false;
    }
    if (account != null) {
      accounts[site] = Account(account.username, downloaded: when);
    }
    onDownloaded?.call();
    return true;
  }

  @override
  Future<bool> setUsername(GameSite site, String? username) async {
    if (rejectUsernames) return false;
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

/// The review over a scripted store holding the tactics set, the real
/// session, saver and set, an engine that answers at once and sites whose
/// answers the test writes. The games cache writes its `.fetched` note to a
/// real folder, which is all of it that touches the disk.
final class ReviewRig {
  ReviewRig({
    GamesFetch? lichess,
    GamesFetch? chesscom,
    ReviewEngine? engine,
    Map<GameSite, Account>? accounts,
    Map<String, EngineLine>? lines,
    DateTime Function() now = DateTime.now,
  }) : engine = AnsweringEngine(lines) {
    this.lichess = ScriptedSite(GameSite.lichess, [
      lichess ?? const GamesFetched([scholarsMate]),
    ]);
    this.chesscom = ScriptedSite(GameSite.chesscom, [
      chesscom ?? const GamesFetched([quietChesscomGame]),
    ]);
    this.accounts = MemoryAccounts(
      accounts ??
          {
            GameSite.lichess: const Account('Me'),
            GameSite.chesscom: const Account('Me'),
          },
    );
    additions = SetAdditions(
      documents: store,
      session: session,
      saver: saver,
      set: set,
    );
    games = MyGames(
      accounts: this.accounts,
      sites: [this.lichess, this.chesscom],
      cache: cache,
      set: additions,
      engine: engine ?? () async => Started(this.engine),
      settings: settings,
      now: now,
    );
  }

  final store = ScriptedDocumentStore()
    ..documents[tacticsRef] = Opened(tacticsSet, scriptedRevision(tacticsSet));
  late final saver = DocumentSaver(store, delay: Duration.zero);
  late final session = DocumentSession(store, saver);
  final settings = SettingsStore();
  late final set = TacticsSet(
    documents: store,
    session: session,
    settings: settings,
    ref: tacticsRef,
  );
  final folder = Directory.systemTemp.createTempSync('v2-my-games-');
  late final cache = GamesCache(
    store,
    folder: (Directory(
      p.join(folder.path, 'games_library'),
    )..createSync()).path,
  );
  final AnsweringEngine engine;
  late final ScriptedSite lichess;
  late final ScriptedSite chesscom;
  late final MemoryAccounts accounts;
  late final SetAdditions additions;
  late final MyGames games;

  String get setText => (store.documents[tacticsRef]! as Opened).text;

  List<Puzzle> get puzzlesOnDisk =>
      puzzlesOf(parseChapter(name: 'Default', text: setText).lines);

  Future<void> start() async {
    await games.load();
    await games.start();
  }

  bool gamesDisposed = false;

  void dispose() {
    if (!gamesDisposed) games.dispose();
    set.dispose();
    session.dispose();
    saver.dispose();
    settings.dispose();
    folder.deleteSync(recursive: true);
  }
}
