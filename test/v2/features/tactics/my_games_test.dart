import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_edits.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/tactics/my_games.dart';
import 'package:chess_auto_prep/v2/features/tactics/my_games_words.dart';
import 'package:chess_auto_prep/v2/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/v2/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/v2/net/recent_games.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/my_games_fixture.dart';
import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';

/// The review over a scripted store holding the tactics set, the real
/// session, saver and set, an engine that answers at once and sites whose
/// answers the test writes. The games cache writes its `.fetched` note to a
/// real folder, which is all of it that touches the disk.
final class _Review {
  _Review({
    GamesFetch? lichess,
    GamesFetch? chesscom,
    ReviewEngine? engine,
    Map<GameSite, Account>? accounts,
  }) {
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
    games = MyGames(
      accounts: this.accounts,
      sites: [this.lichess, this.chesscom],
      cache: cache,
      set: SetAdditions(
        documents: store,
        session: session,
        saver: saver,
        set: set,
        older: () async => {},
      ),
      engine: engine ?? () async => Started(this.engine),
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
  final engine = AnsweringEngine();
  late final ScriptedSite lichess;
  late final ScriptedSite chesscom;
  late final MemoryAccounts accounts;
  late final MyGames games;

  String get setText => (store.documents[tacticsRef]! as Opened).text;

  List<Puzzle> get puzzlesOnDisk =>
      puzzlesOf(parseChapter(name: 'Default', text: setText).lines);

  Future<void> start() async {
    await games.load();
    await games.start();
  }

  void dispose() {
    games.dispose();
    set.dispose();
    session.dispose();
    saver.dispose();
    settings.dispose();
    folder.deleteSync(recursive: true);
  }
}

void main() {
  late _Review r;

  tearDown(() => r.dispose());

  test('downloads, reviews and adds each mistake to the set, marking each '
      'game done', () async {
    r = _Review();
    await r.start();

    expect(r.games.status, isA<MyGamesDone>());
    final done = r.games.status as MyGamesDone;
    expect(done.reviewed, 2);
    expect(done.added, 1);
    expect(r.games.newPuzzles, 1);
    expect(myGamesLine(done), 'Review complete · 1 new puzzle');
    expect(r.puzzlesOnDisk, hasLength(6));
    expect(r.setText, endsWith('$scholarsMatePuzzle\n'));
    expect(analyzedIn(r.setText), {
      'lichess_abc',
      'lichess_AbCd1234',
      'chesscom_111',
    });
    expect(r.engine.quitCalled, isTrue);
    // The set shown in the list has the new puzzle.
    expect(r.set.puzzles, hasLength(6));
    // The download is kept for next time, and dated.
    expect(r.games.accounts[GameSite.lichess]?.downloaded, isNotNull);
    expect(await r.cache.read(GameSite.lichess, 'Me', max: 20), [scholarsMate]);
  });

  test('a game either app has reviewed is never reviewed again', () async {
    r = _Review();
    await r.start();
    final asked = r.engine.asked.length;
    final text = r.setText;

    await r.games.start();

    expect(r.engine.asked, hasLength(asked));
    expect(r.setText, text);
    expect((r.games.status as MyGamesDone).reviewed, 0);
  });

  test('pause stops after the game being reviewed; start carries on '
      'without downloading again', () async {
    r = _Review();
    String? said;
    r.engine.onSearch = () {
      r.engine.onSearch = null;
      r.games.pause();
      said = myGamesLine(r.games.status);
    };
    await r.start();
    expect(said, 'Pausing…');

    expect(r.games.status, isA<MyGamesPaused>());
    expect(myGamesLine(r.games.status), 'Paused — 1 game left');
    expect(r.games.queued, 1);
    expect(r.puzzlesOnDisk, hasLength(6));

    await r.games.start();

    expect(r.lichess.asked, hasLength(1));
    final done = r.games.status as MyGamesDone;
    expect(done.added, 1);
    expect(analyzedIn(r.setText), contains('chesscom_111'));
  });

  test(
    'a site that cannot be reached is answered from its saved games',
    () async {
      r = _Review(
        lichess: const GamesNotFetched(GamesProblem.unreachable),
        chesscom: const GamesNotFetched(GamesProblem.unreachable),
      );
      await r.cache.keep(GameSite.lichess, 'Me', [
        scholarsMate,
      ], DateTime(2026));
      await r.start();

      final done = r.games.status as MyGamesDone;
      expect(done.added, 1);
      expect(done.notReached, {GameSite.lichess, GameSite.chesscom});
      expect(
        myGamesLine(done),
        'Review complete · 1 new puzzle · Lichess and Chess.com not reached, '
        'using saved games',
      );
    },
  );

  test(
    'offline with nothing saved says so, per site, and writes nothing',
    () async {
      r = _Review(
        lichess: const GamesNotFetched(GamesProblem.unreachable),
        accounts: {GameSite.lichess: const Account('Me')},
      );
      await r.start();

      expect(r.games.status, isA<MyGamesNotDownloaded>());
      expect(
        myGamesLine(r.games.status),
        'Could not reach Lichess, and no games are saved.',
      );
      expect(r.setText, tacticsSet);
      expect(r.engine.asked, isEmpty);
    },
  );

  test('no username, no download', () async {
    r = _Review(accounts: const {});
    await r.start();
    expect(myGamesLine(r.games.status), 'Set a username first.');
    expect(r.lichess.asked, isEmpty);
  });

  test('no engine fails the review and keeps the games queued', () async {
    r = _Review(engine: () async => const StartFailed('no Stockfish'));
    await r.start();
    expect(myGamesLine(r.games.status), 'Analysis failed: no Stockfish.');
    expect(r.games.queued, 2);
    expect(r.setText, tacticsSet);
  });

  test('saving usernames downloads nothing and forgets the other account\'s '
      'date', () async {
    r = _Review(
      accounts: {GameSite.lichess: Account('Old', downloaded: DateTime(2026))},
    );
    await r.games.load();
    expect(await r.games.saveUsernames(lichess: 'Me', chesscom: ' '), isTrue);
    expect(r.games.accounts.keys, [GameSite.lichess]);
    expect(r.games.accounts[GameSite.lichess]?.username, 'Me');
    expect(r.games.accounts[GameSite.lichess]?.downloaded, isNull);
    expect(r.lichess.asked, isEmpty);
    expect(r.games.status, isA<MyGamesIdle>());
  });

  test('with a puzzle up, the puzzles go in through the session and keep '
      'the attempt it is still saving', () async {
    r = _Review();
    await r.session.open(tacticsRef, game: 0);
    r.session.apply(
      (set) => recordAttempt(
        set,
        index: 0,
        solved: true,
        seconds: 4,
        now: tacticsToday,
      ),
    );
    await r.start();

    expect(r.games.status, isA<MyGamesDone>());
    final onDisk = r.puzzlesOnDisk;
    expect(onDisk, hasLength(6));
    expect(onDisk.first.stats.reviews, 1);
    expect(r.session.game, 0);
    expect(r.saver.settled, isTrue);
  });

  test('the set changed on disk under the review is read again, not '
      'overwritten', () async {
    r = _Review();
    r.store.saves.add(const Conflict(null));
    await r.start();

    expect(r.games.status, isA<MyGamesDone>());
    expect(r.puzzlesOnDisk, hasLength(6));
    expect(r.store.requestedSaves.length, greaterThanOrEqualTo(3));
  });
}
