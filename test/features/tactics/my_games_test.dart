import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/chess/pgn/study_edits.dart';
import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tactics/mistake_counts.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle_edits.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/features/tactics/my_games_words.dart';
import 'package:chess_auto_prep/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/net/recent_games.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
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
    Future<Set<String>?> Function()? older,
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
      older: older ?? () async => {},
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

  test(
    'the review writes each game\'s mistake counts with its done mark',
    () async {
      r = _Review();
      await r.start();
      final counts = mistakesIn(
        parseChapter(name: 'Default', text: r.setText).preamble,
      );
      expect(counts['lichess_AbCd1234']?.blunders, greaterThan(0));
      expect(counts['chesscom_111'], const MistakeCounts());
      expect(analyzedIn(r.setText), contains('lichess_AbCd1234'));
    },
  );

  test('only games of the chosen time controls are reviewed', () async {
    const bullet = '[TimeControl "60+0"]\n';
    r = _Review(
      accounts: {GameSite.lichess: const Account('Me')},
      lichess: GamesFetched([
        scholarsMate.replaceFirst('[Result', '$bullet[Result'),
      ]),
    );
    await r.games.load();
    r.games.setSpeeds({GameSpeed.blitz, GameSpeed.rapid});
    expect(r.settings.value.myGameSpeeds, {GameSpeed.blitz, GameSpeed.rapid});
    await r.games.start();
    expect((r.games.status as MyGamesDone).reviewed, 0);
    expect(analyzedIn(r.setText), isNot(contains('lichess_AbCd1234')));
    r.games.setSpeeds({});
    expect(r.games.speeds, hasLength(2), reason: 'never no speeds at all');
  });

  test('a download that cannot be saved is still reviewed and blocks '
      'nothing', () async {
    r = _Review(accounts: {GameSite.lichess: const Account('Me')});
    r.store.creates.add(const IoFailure('disk full'));
    await r.start();
    expect(r.games.status, isA<MyGamesDone>());
    expect((r.games.status as MyGamesDone).reviewed, 1);
    expect(r.games.accounts[GameSite.lichess]!.downloaded, isNull);
    expect(await r.games.saveUsernames(lichess: 'Other'), isTrue);
    expect(r.games.accounts[GameSite.lichess]!.username, 'Other');
  });

  test('one failed save leaves the other site saved and reviewed', () async {
    r = _Review();
    r.store.creates.add(const IoFailure('disk full'));
    await r.start();
    expect(r.games.accounts[GameSite.chesscom]!.downloaded, isNotNull);
    expect(analyzedIn(r.setText), contains('chesscom_111'));
    await r.games.start();
    expect(r.lichess.asked, hasLength(2), reason: 'the next start downloads');
  });

  test(
    'a failed download date is logged and the next download dates it',
    () async {
      final when = DateTime(2026, 9, 24);
      r = _Review(
        accounts: {GameSite.lichess: const Account('Me')},
        now: () => when,
      );
      r.accounts.rejectDownloaded = true;
      await r.start();
      expect(r.games.accounts[GameSite.lichess]!.downloaded, isNull);
      expect(await r.cache.all(GameSite.lichess, 'Me'), [scholarsMate]);
      r.accounts.rejectDownloaded = false;
      await r.games.start();
      expect(r.games.accounts[GameSite.lichess]!.downloaded, when);
    },
  );

  test(
    'thrown fetch keeps offline corpus and the other site independent',
    () async {
      r = _Review();
      await r.cache.keep(GameSite.lichess, 'Me', [
        scholarsMate,
      ], DateTime(2026));
      r.lichess.error = StateError('network disappeared');
      await r.start();
      expect((r.games.status as MyGamesDone).notReached, {GameSite.lichess});
      expect(
        analyzedIn(r.setText),
        containsAll(['lichess_AbCd1234', 'chesscom_111']),
      );
      expect(await r.cache.all(GameSite.lichess, 'Me'), [scholarsMate]);
    },
  );

  test('accounts that cannot be read keep the names already shown', () async {
    r = _Review(accounts: {GameSite.lichess: const Account('Me')});
    await r.games.load();
    r.accounts.unavailable = true;
    await r.games.load();
    expect(r.games.accounts[GameSite.lichess]?.username, 'Me');
    await r.games.start();
    expect(r.lichess.asked, hasLength(1));
  });

  test('an unreadable saved file with no network reviews nothing and says '
      'the site was not reached', () async {
    r = _Review(
      accounts: {GameSite.lichess: const Account('Me')},
      lichess: const GamesNotFetched(GamesProblem.unreachable),
    );
    r.store.documents[r.cache.refFor(GameSite.lichess, 'Me')] =
        const Unreadable('permission denied');
    await r.start();
    expect(r.games.status, isA<MyGamesNotDownloaded>());
    expect(r.engine.asked, isEmpty);
    await r.games.start();
    expect(r.lichess.asked, hasLength(2), reason: 'start tries again');
  });

  test('a username save that failed does not block downloads', () async {
    r = _Review(accounts: {GameSite.lichess: const Account('Me')});
    await r.games.load();
    r.accounts.rejectUsernames = true;
    expect(await r.games.saveUsernames(lichess: 'New'), isFalse);
    expect(r.games.accountProblem, isNotNull);
    expect(r.games.accountsUnsettled, isFalse);
    await r.games.start();
    expect(r.lichess.asked, ['Me'], reason: 'the saved name is used');
    r.accounts.rejectUsernames = false;
    expect(await r.games.saveUsernames(lichess: 'New'), isTrue);
    expect(r.games.accountProblem, isNull);
    expect(await r.games.pendingWrites.settle(), isNull);
  });

  test(
    'accepting a checkpoint freezes the mined puzzle list before awaiting',
    () async {
      r = _Review();
      final found = [minedScholarsMate()];
      final adding = r.additions.add('lichess_AbCd1234', found);
      found.clear();
      expect((await adding as Added).added, 1);
      expect(r.puzzlesOnDisk, hasLength(6));
    },
  );

  for (final replace in [false, true]) {
    test(
      'a ${replace ? 'different puzzle at the same FEN' : 'deleted puzzle'} cannot certify the failed checkpoint',
      () async {
        r = _Review(accounts: {GameSite.lichess: const Account('Me')});
        await r.session.open(tacticsRef, game: 0);
        r.store.saves.add(const IoFailure('set disk full'));
        await r.start();
        if (replace) {
          final other = parseChapter(
            name: 'Default',
            text: scholarsMatePuzzle.replaceAll(
              'lichess_AbCd1234',
              'lichess_other',
            ),
          ).lines.single;
          r.session.apply(
            (chapter) => ChapterEdited(
              withLines(chapter, [...chapter.lines.take(5), other]),
              GamesArranged(order: [0, 1, 2, 3, 4, null], before: 6),
            ),
          );
        } else {
          r.session.apply((chapter) => deleteChapter(chapter, index: 5));
        }
        await r.games.start();
        expect(r.games.status, isA<MyGamesFailed>());
        expect(r.games.newPuzzles, 0);
        expect(
          r.puzzlesOnDisk,
          hasLength(replace ? 6 : 5),
          reason: 'deleted accepted output is not reinserted',
        );
        expect(
          r.puzzlesOnDisk.where(
            (puzzle) => puzzle.gameId == 'lichess_AbCd1234',
          ),
          isEmpty,
        );
        expect(await r.games.pendingWrites.settle(), isNotNull);
      },
    );
  }

  test(
    'review metadata on the appended puzzle preserves checkpoint identity',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      await r.session.open(tacticsRef, game: 0);
      r.store.saves.add(const IoFailure('set disk full'));
      await r.start();
      r.session.apply(
        (chapter) => recordAttempt(
          chapter,
          index: 5,
          fen: puzzleOf(chapter.lines[5], 5)!.fen,
          solved: true,
          seconds: 4,
          now: tacticsToday,
        ),
      );
      await r.games.start();
      expect((r.games.status as MyGamesDone).added, 1);
      expect(r.puzzlesOnDisk.last.stats.reviews, 1);
      expect(await r.games.pendingWrites.settle(), isNull);
    },
  );

  test(
    'a throwing engine factory reports failure and keeps queued input',
    () async {
      r = _Review(
        accounts: {GameSite.lichess: const Account('Me')},
        engine: () async => throw StateError('engine launch failed'),
      );
      await r.start();
      expect(r.games.status, isA<MyGamesFailed>());
      expect(r.games.running, isFalse);
      expect(r.games.queued, 1);
      expect(myGamesLine(r.games.status), contains('engine launch failed'));
      expect(analyzedIn(r.setText), isNot(contains('lichess_AbCd1234')));
    },
  );

  test(
    'a late engine after disposal is released even when quit fails',
    () async {
      final launch = Completer<EngineStart>();
      final requested = Completer<void>();
      r = _Review(
        accounts: {GameSite.lichess: const Account('Me')},
        engine: () {
          requested.complete();
          return launch.future;
        },
      );
      final running = r.start();
      await requested.future;
      expect(r.games.status, isA<MyGamesReviewing>());
      r.engine.quitError = StateError('late exit failed');
      r.games.dispose();
      r.gamesDisposed = true;
      launch.complete(Started(r.engine));
      await running;
      expect(r.engine.quitCalls, 1);
      expect(r.engine.asked, isEmpty);
    },
  );

  test('disposal and review cleanup share one handled engine quit', () async {
    r = _Review(accounts: {GameSite.lichess: const Account('Me')});
    r.engine.quitError = StateError('exit failed during disposal');
    r.engine.onSearch = () {
      r.engine.onSearch = null;
      r.games.dispose();
      r.gamesDisposed = true;
    };
    await r.start();
    expect(r.engine.quitCalls, 1);
    expect(analyzedIn(r.setText), isNot(contains('lichess_AbCd1234')));
  });

  test(
    'an engine quit failure stays visible and retains the saved count',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      r.engine.quitError = StateError('engine exit acknowledgement failed');
      await r.start();
      expect(r.games.status, isA<MyGamesFailed>());
      expect(r.games.running, isFalse);
      expect(r.games.newPuzzles, 1);
      expect(
        myGamesLine(r.games.status),
        contains('engine exit acknowledgement failed'),
      );
      expect(r.puzzlesOnDisk, hasLength(6));
      expect(r.engine.quitCalled, isTrue);
    },
  );

  test(
    'an unexpected mining failure releases the engine and reports failure',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      r.engine.onSearch = () => throw StateError('search transport failed');
      await r.start();
      expect(r.games.status, isA<MyGamesFailed>());
      expect(r.engine.quitCalled, isTrue);
      expect(r.games.running, isFalse);
      expect(analyzedIn(r.setText), isNot(contains('lichess_AbCd1234')));
    },
  );

  test('an unsaved mined marker is not an analyzed checkpoint', () async {
    r = _Review(accounts: {GameSite.lichess: const Account('Me')});
    await r.session.open(tacticsRef, game: 0);
    r.store.saves.add(const IoFailure('set disk full'));
    await r.start();
    expect(r.games.status, isA<MyGamesFailed>());
    expect(
      analyzedIn(r.session.chapter!.preamble),
      contains('lichess_AbCd1234'),
    );
    expect(await r.additions.analyzed(), isNot(contains('lichess_AbCd1234')));
    expect(await r.games.pendingWrites.settle(), contains('set'));
  });

  test(
    'retry saves the captured mined result and its original added count',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      r.store.saves.add(const IoFailure('set disk full'));
      await r.start();
      final searches = r.engine.asked.length;
      expect(r.games.status, isA<MyGamesFailed>());
      await r.games.start();
      expect(
        r.engine.asked,
        hasLength(searches),
        reason: 'retry performs no mining',
      );
      expect((r.games.status as MyGamesDone).added, 1);
      expect(r.puzzlesOnDisk, hasLength(6));
      expect(await r.games.pendingWrites.settle(), isNull);
    },
  );

  test(
    'open-set retry neither skips an unsaved game nor loses its added count',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      await r.session.open(tacticsRef, game: 0);
      r.store.saves.add(const IoFailure('set disk full'));
      await r.start();
      final searches = r.engine.asked.length;
      await r.games.start();
      expect((r.games.status as MyGamesDone).added, 1);
      expect(r.puzzlesOnDisk, hasLength(6));
      expect(r.saver.settled, isTrue);
      expect(r.engine.asked, hasLength(searches));
    },
  );

  test(
    'accepted mined puzzles survive disposal of the reviewing owner',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      r.store.saves.add(const IoFailure('set disk full'));
      await r.start();
      final entries = r.games.pendingWrites.unfinished(r.additions);
      expect(entries, hasLength(1));
      r.games.dispose();
      r.gamesDisposed = true;
      await r.games.pendingWrites.retry(r.additions);
      expect(r.puzzlesOnDisk, hasLength(6));
      expect(analyzedIn(r.setText), contains('lichess_AbCd1234'));
      expect(await r.games.pendingWrites.settle(), isNull);
    },
  );

  test(
    'a registry-completed checkpoint is counted once without a new engine',
    () async {
      r = _Review(accounts: {GameSite.lichess: const Account('Me')});
      r.store.saves.add(const IoFailure('set disk full'));
      await r.start();
      final searches = r.engine.asked.length;
      await r.games.pendingWrites.retry(r.additions);
      expect(r.puzzlesOnDisk, hasLength(6));
      await r.games.start();
      expect((r.games.status as MyGamesDone).added, 1);
      expect(r.engine.asked, hasLength(searches));
      await r.games.start();
      expect((r.games.status as MyGamesDone).added, 0);
      expect(r.puzzlesOnDisk, hasLength(6));
    },
  );

  group('a checkpoint left behind by a new queue', () {
    final blitz = scholarsMate.replaceFirst(
      '[Result',
      '[TimeControl "180+0"]\n[Result',
    );
    // Me, with Black, walks into mate with `3... Nf6??` from another
    // position than [scholarsMate]'s, so its puzzle is its own.
    const rapid = '''
[Event "Rated rapid game"]
[Site "https://lichess.org/Rapid001"]
[Date "2026.09.21"]
[White "Rival"]
[Black "Me"]
[Result "1-0"]
[UTCDate "2026.09.21"]
[UTCTime "10:00:00"]
[TimeControl "600+0"]

1. e4 e5 2. Bc4 Bc5 3. Qh5 Nf6 4. Qxf7# 1-0''';
    final lines = {
      ...scholarsMateLines,
      const Fen(
        'rnbqk1nr/pppp1ppp/8/2b1p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3',
      ).position: const EngineLine(
        multiPv: 1,
        depth: 15,
        score: Centipawns(0),
        pv: ['d8e7', 'g1f3'],
      ),
      const Fen(
        'rnbqk2r/pppp1ppp/5n2/2b1p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
      ).position: const EngineLine(
        multiPv: 1,
        depth: 15,
        score: MateIn(1),
        pv: ['h5f7'],
      ),
    };

    int setSaves() => r.store.requestedSaves
        .where((save) => save.ref.path == tacticsRef.path)
        .length;

    Future<void> failBlitzThenPickRapid() async {
      r = _Review(
        accounts: {GameSite.lichess: const Account('Me')},
        lichess: GamesFetched([blitz, rapid]),
        lines: lines,
      );
      await r.games.load();
      r.games.setSpeeds({GameSpeed.blitz});
      r.store.saves.add(const IoFailure('set disk full'));
      await r.games.start();
      expect(
        (r.games.status as MyGamesFailed).problem,
        MyGamesProblem.notSaved,
      );
      r.games.setSpeeds({GameSpeed.rapid});
    }

    void expectBothSaved() {
      expect(r.games.status, isA<MyGamesDone>());
      expect({
        for (final puzzle in r.puzzlesOnDisk) puzzle.gameId,
      }, containsAll(['lichess_AbCd1234', 'lichess_Rapid001']));
      expect(
        analyzedIn(r.setText),
        containsAll(['lichess_AbCd1234', 'lichess_Rapid001']),
      );
    }

    test('is saved ahead of the next game rather than blocking it', () async {
      await failBlitzThenPickRapid();
      await r.games.start();
      expectBothSaved();
      expect(await r.games.pendingWrites.settle(), isNull);
    });

    test('is tried again at every start until the set can be saved', () async {
      await failBlitzThenPickRapid();
      r.store.saves.add(const IoFailure('set disk full'));
      await r.games.start();
      expect(r.games.status, isA<MyGamesFailed>());
      expect(setSaves(), 2, reason: 'the earlier game was tried again');
      final searches = r.engine.asked.length;
      r.store.saves.add(const IoFailure('set disk full'));
      await r.games.start();
      expect(r.games.status, isA<MyGamesFailed>());
      expect(setSaves(), 3);
      await r.games.start();
      expectBothSaved();
      expect(
        r.engine.asked,
        hasLength(searches),
        reason: 'no game is mined twice',
      );
      expect(await r.games.pendingWrites.settle(), isNull);
    });
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

  test('a Lichess game the old app filed under its bare id is not reviewed '
      'again', () async {
    r = _Review(accounts: {GameSite.lichess: const Account('Me')});
    final withBare = withAnalyzed(tacticsSet, {
      ...analyzedIn(tacticsSet),
      'AbCd1234',
    });
    r.store.documents[tacticsRef] = Opened(
      withBare,
      scriptedRevision(withBare),
    );
    await r.start();
    expect((r.games.status as MyGamesDone).reviewed, 0);
    expect(r.engine.asked, isEmpty);
    expect(r.setText, withBare);
  });

  test('a bare Lichess id in the old app\'s own list keeps its game from '
      'being reviewed', () async {
    final documents = Directory.systemTemp.createTempSync('v2-older-ids-');
    addTearDown(() => documents.deleteSync(recursive: true));
    File(
      p.join(documents.path, 'analyzed_games.txt'),
    ).writeAsStringSync('AbCd1234\n');
    r = _Review(
      accounts: {GameSite.lichess: const Account('Me')},
      older: () => readOlderAnalyzed(documents),
    );
    await r.start();
    expect((r.games.status as MyGamesDone).reviewed, 0);
    expect(r.engine.asked, isEmpty);
    expect(r.setText, tacticsSet);
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

  test('a review carried on after the engine would not start still counts '
      'the puzzles it added before', () async {
    var starts = 0;
    r = _Review(
      engine: () async =>
          ++starts == 2 ? const StartFailed('no Stockfish') : Started(r.engine),
    );
    r.engine.onSearch = () {
      r.engine.onSearch = null;
      r.games.pause();
    };
    await r.start();
    expect(r.games.newPuzzles, 1);

    await r.games.start();
    expect(r.games.status, isA<MyGamesFailed>());
    expect(r.games.newPuzzles, 1);

    await r.games.start();
    expect((r.games.status as MyGamesDone).added, 1);
  });

  test('a download is dated by the clock the review is given', () async {
    final when = DateTime(2026, 9, 22, 10, 30);
    r = _Review(now: () => when);
    await r.start();
    expect(r.games.accounts[GameSite.lichess]?.downloaded, when);
    final ref = r.cache.refFor(GameSite.lichess, 'Me');
    expect(
      File('${ref.path}.fetched').readAsStringSync(),
      '${when.millisecondsSinceEpoch}',
    );
  });

  test('an old app\'s list of reviewed games that cannot be read stops the '
      'review before anything is mined', () async {
    r = _Review(older: () async => null);
    await r.start();
    expect(
      (r.games.status as MyGamesFailed).problem,
      MyGamesProblem.setUnreadable,
    );
    expect(r.engine.asked, isEmpty);
    expect(r.setText, tacticsSet);
  });

  test(
    'opening a set waits for its accepted checkpoint before editing it',
    () async {
      r = _Review();
      r.store.hold = true;
      final adding = r.additions.add('lichess_AbCd1234', [minedScholarsMate()]);
      await pumpEventQueue();
      expect(r.store.waiting, 1, reason: 'the review is reading the set');
      final opening = r.session.open(tacticsRef, game: 0);
      await pumpEventQueue();
      expect(
        r.store.waiting,
        1,
        reason: 'navigation waits behind the checkpoint',
      );
      expect(r.session.source, isNull);
      r.store.hold = false;
      r.store.releaseAll();
      expect(await adding, isA<Added>());
      await opening;
      expect(r.session.source, tacticsRef);

      expect(r.session.chapter!.lines, hasLength(6));
      r.session.apply(
        (set) => recordAttempt(
          set,
          index: 0,
          fen: puzzleOf(set.lines[0], 0)!.fen,
          solved: true,
          seconds: 4,
          now: tacticsToday,
        ),
      );
      await r.saver.flush();
      expect(r.saver.settled, isTrue);
      expect(r.puzzlesOnDisk, hasLength(6));
      expect(r.puzzlesOnDisk.first.stats.reviews, 1);
    },
  );

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
        fen: puzzleOf(set.lines[0], 0)!.fen,
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
