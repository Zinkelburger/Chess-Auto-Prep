import 'dart:async';

import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/session_fixture.dart';

const chapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

/// A line long enough to walk three empty answers down.
const longerLine = '''
// Color: White

[Event "Spanish"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *
''';

/// A chapter rooted at move 26, past which nothing is asked.
const deepChapter = '''
// Color: White

[Event "Deep"]
[Result "*"]
[FEN "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R2QK2R w KQ - 4 26"]
[SetUp "1"]

26. O-O *
''';

/// Two ways to start, each five plies long: 1. e4 on the main line, 1. d4
/// as its variation.
const twoBranches = '''
// Color: White

[Event "Branches"]
[Result "*"]

1. e4 (1. d4 d5 2. c4 e6 3. Nc3) e5 2. Nf3 Nc6 3. Bb5 *
''';

/// A Lichess explorer that holds every answer until the test gives it, so
/// the board can move while a request is out.
final class HeldExplorerApi implements LichessExplorer {
  final _out = <Completer<ExplorerFetch>>[];

  /// How many requests are waiting for their answer.
  int get waiting => _out.length;

  /// Answers the oldest request still out.
  void answer(ExplorerFetch fetch) => _out.removeAt(0).complete(fetch);

  @override
  Future<ExplorerFetch> fetch(ExplorerQuery query) {
    final out = Completer<ExplorerFetch>();
    _out.add(out);
    return out.future;
  }

  @override
  Future<String?> gamePgn(String id, {required bool masters}) async => null;
}

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late ScriptedExplorerApi lichess;
  late ScriptedBook book;
  late ScriptedLocalGames thisFile;
  late ScriptedLocalGames myGames;
  late Explorer explorer;

  setUp(() async {
    fixture = await openSession(chapter);
    settings = SettingsStore();
    lichess = ScriptedExplorerApi();
    book = ScriptedBook(present: true);
    thisFile = ScriptedLocalGames();
    myGames = ScriptedLocalGames();
  });

  tearDown(() {
    explorer.dispose();
    settings.dispose();
    fixture.dispose();
  });

  Future<void> start() async {
    explorer = explorerOver(
      fixture.session,
      settings: settings,
      lichess: lichess,
      book: book,
      thisFile: thisFile,
      myGames: myGames,
    );
    await pumpEventQueue();
  }

  ExplorerShown shown() => explorer.state as ExplorerShown;

  test('the table is the database\'s moves at the board, spelled for the '
      'position, ticked where the chapter plays them', () async {
    await start();
    final rows = shown().rows;
    expect(rows.map((r) => r.san), ['e4', 'd4']);
    expect(rows.first.share, '60%');
    expect(rows.first.inRepertoire, isTrue);
    expect(rows.last.inRepertoire, isFalse);
    expect(rows.first.after.value, startsWith('rnbqkbnr/pppppppp/8/8/4P3'));
    expect(shown().answer.games.single.id, 'abcd1234');
    expect(lichess.asked.single.masters, isTrue);
    expect(explorer.sources, contains(ExplorerSource.twic));
  });

  test('moving the cursor asks about the new position; coming back is '
      'answered from the cache without asking', () async {
    lichess.answer = (query) =>
        ExplorerFetched(query.fen == Fen.initial ? startAnswer : afterE4Answer);
    await start();
    fixture.session.forward();
    expect(explorer.state, isA<ExplorerAsking>());
    await pumpEventQueue();
    expect(shown().rows.single.san, 'e5');
    fixture.session.back();
    expect(shown().rows.first.san, 'e4', reason: 'at once');
    await pumpEventQueue();
    expect(lichess.asked, hasLength(2));
  });

  test('a fetch that throws, one that returns nothing, a 429 and a 500 '
      'each say so, and Try again asks again', () async {
    lichess.throwing = StateError('boom');
    await start();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'Could not ask Masters.',
    );
    lichess.throwing = null;
    lichess.answer = (_) => const ExplorerFetched(ExplorerAnswer.empty);
    await explorer.retry();
    expect(
      (explorer.state as ExplorerNothing).sentence,
      'No games found for this position.',
    );
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.rateLimited);
    await explorer.retry();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'Lichess is rate-limiting requests.',
    );
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.http, status: 500);
    await explorer.retry();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'Lichess could not answer. It answered HTTP 500.',
    );
    expect(lichess.asked, hasLength(4));
  });

  test('offline, the sentence names TWIC when it is on this machine', () async {
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.unreachable);
    await start();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'Could not reach the Lichess database — it needs a connection. '
      'TWIC works offline.',
    );
    book.present = false;
    await explorer.retry();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'Could not reach the Lichess database — it needs a connection.',
    );
    expect(explorer.sources, isNot(contains(ExplorerSource.twic)));
  });

  test('a forced refresh that fails keeps the rows on the screen, with one '
      'line saying why; the next answer clears it', () async {
    await start();
    lichess.throwing = StateError('boom');
    await explorer.retry();
    expect(explorer.state, isA<ExplorerShown>(), reason: 'kept');
    expect(shown().rows.first.san, 'e4');
    expect(explorer.notice, 'Could not ask Masters.');
    lichess.throwing = null;
    await explorer.retry();
    expect(explorer.notice, isNull);
  });

  test('a failure takes nothing from the cache: a position answered before '
      'still shows when the cursor returns', () async {
    lichess.answer = (query) => query.fen == Fen.initial
        ? const ExplorerFetched(startAnswer)
        : const ExplorerNotFetched(ExplorerProblem.http, status: 500);
    await start();
    fixture.session.forward();
    await pumpEventQueue();
    expect(explorer.state, isA<ExplorerFailed>());
    fixture.session.back();
    expect(shown().rows.first.san, 'e4');
  });

  test('two services fail on their own: TWIC answers while Lichess cannot, '
      'and the choice is written to the settings', () async {
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.unreachable);
    await start();
    expect(explorer.state, isA<ExplorerFailed>());
    explorer.choose(explorer.choice.copyWith(source: ExplorerSource.twic));
    await pumpEventQueue();
    expect(settings.value.explorer.source, ExplorerSource.twic);
    expect(shown().rows.first.san, 'e4');
    expect(book.asked.single.$2, isFalse, reason: 'every game');
    explorer.choose(explorer.choice.copyWith(classicalOnly: true));
    await pumpEventQueue();
    expect(book.asked.last.$2, isTrue);
    explorer.choose(explorer.choice.copyWith(source: ExplorerSource.lichess));
    await pumpEventQueue();
    expect(explorer.state, isA<ExplorerFailed>());
    explorer.choose(explorer.choice.copyWith(source: ExplorerSource.twic));
    expect(shown().rows.first.san, 'e4', reason: 'from the cache');
  });

  test('a book that is unreadable or missing says so', () async {
    settings = SettingsStore(
      initial: const Settings(
        explorer: ExplorerChoice(source: ExplorerSource.twic),
      ),
    );
    book.answer = (_, _) => const BookUnreadable('locked');
    await start();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'The master database could not be read.',
    );
    book.answer = (_, _) => const BookAbsent();
    await explorer.retry();
    expect(
      (explorer.state as ExplorerFailed).sentence,
      'There is no master database on this machine.',
    );
  });

  test('after three empty answers going deeper the line is left alone, '
      'and Try again asks even so', () async {
    fixture = await openSession(longerLine);
    var empties = 0;
    lichess.answer = (query) {
      if (query.fen == Fen.initial) return const ExplorerFetched(startAnswer);
      empties++;
      return const ExplorerFetched(ExplorerAnswer.empty);
    };
    await start();
    for (var i = 0; i < 3; i++) {
      fixture.session.forward();
      await pumpEventQueue();
      expect(explorer.state, isA<ExplorerNothing>());
    }
    expect(empties, 3);
    fixture.session.forward();
    await pumpEventQueue();
    expect(explorer.state, isA<ExplorerNothing>());
    expect(empties, 3, reason: 'not asked again on this line');
    fixture.session.toStart();
    fixture.session.forward();
    await explorer.retry();
    expect(empties, 4);
  });

  test('three empty answers down one branch leave another branch to be '
      'asked, however deep', () async {
    fixture = await openSession(twoBranches);
    lichess.answer = (query) => query.fen == Fen.initial
        ? const ExplorerFetched(startAnswer)
        : const ExplorerFetched(ExplorerAnswer.empty);
    await start();
    for (var i = 0; i < 3; i++) {
      fixture.session.forward();
      await pumpEventQueue();
    }
    final asked = lichess.asked.length;
    fixture.session.forward();
    await pumpEventQueue();
    expect(lichess.asked, hasLength(asked), reason: 'this line is left');
    // 1. d4 d5 2. c4 e6: as deep, on the other branch.
    fixture.session.goTo(NodePath.of(const [1, 0, 0, 0]));
    await pumpEventQueue();
    expect(lichess.asked, hasLength(asked + 1));
    expect(lichess.asked.last.fen, fixture.session.fen);
  });

  test('a refresh that failed says so beside its own rows only', () async {
    await start();
    lichess.throwing = StateError('boom');
    await explorer.retry();
    expect(explorer.notice, 'Could not ask Masters.');
    lichess.throwing = null;
    fixture.session.forward();
    await pumpEventQueue();
    expect(explorer.notice, isNull);
  });

  group('an answer that lands after the board has moved on', () {
    late HeldExplorerApi held;

    /// The explorer over [held], with the start position and 1. e4 both
    /// answered and the board back at the start.
    Future<void> startHeld() async {
      held = HeldExplorerApi();
      explorer = Explorer(
        session: fixture.session,
        settings: settings,
        databases: ExplorerDatabases(
          lichess: held,
          book: book,
          thisFile: thisFile,
          myGames: myGames,
        ),
        debounce: Duration.zero,
      );
      await pumpEventQueue();
      held.answer(const ExplorerFetched(startAnswer));
      await pumpEventQueue();
      fixture.session.forward();
      await pumpEventQueue();
      held.answer(const ExplorerFetched(afterE4Answer));
      await pumpEventQueue();
      fixture.session.back();
      expect(shown().rows.first.san, 'e4', reason: 'from the cache');
    }

    const failure = ExplorerNotFetched(ExplorerProblem.http, status: 500);

    test('a failure leaves the rows of the position on the board', () async {
      await startHeld();
      fixture.session.forward();
      fixture.session.forward();
      await pumpEventQueue();
      expect(held.waiting, 1, reason: '1. e4 e5 is being asked about');
      fixture.session.back();
      expect(shown().rows.single.san, 'e5', reason: 'from the cache');
      held.answer(failure);
      await pumpEventQueue();
      expect(shown().rows.single.san, 'e5');
      expect(explorer.notice, isNull);
    });

    test('Try again that fails after the board moved does not bring its '
        'rows to the new position', () async {
      await startHeld();
      final retrying = explorer.retry();
      await pumpEventQueue();
      expect(held.waiting, 1, reason: 'the start is being asked again');
      fixture.session.forward();
      expect(shown().rows.single.san, 'e5', reason: 'from the cache');
      held.answer(failure);
      await retrying;
      expect(shown().rows.single.san, 'e5');
      expect(explorer.notice, isNull);
    });

    test('Try again and a move before it asks: the position left is not '
        'asked about', () async {
      await startHeld();
      unawaited(explorer.retry());
      fixture.session.forward();
      await pumpEventQueue();
      expect(held.waiting, 0);
      expect(shown().rows.single.san, 'e5');
      expect(explorer.notice, isNull);
    });
  });

  test('past move 25 nothing is asked', () async {
    fixture = await openSession(deepChapter);
    await start();
    expect(explorer.ply, 50);
    expect(explorer.state, isA<ExplorerShown>(), reason: 'still asked');
    fixture.session.forward();
    await pumpEventQueue();
    expect(
      (explorer.state as ExplorerNothing).sentence,
      'The database is not asked past move 25.',
    );
    expect(lichess.asked, hasLength(1));
  });

  test('closing the file asks about the analysis board instead', () async {
    await start();
    fixture.session.closed();
    expect(explorer.state, isNot(isA<ExplorerIdle>()));
  });

  group('the games on this machine:', () {
    Future<void> choose(ExplorerSource source) async {
      await start();
      explorer.choose(ExplorerChoice(source: source));
      await pumpEventQueue();
    }

    test('This file and My games are listed after the databases', () async {
      await start();
      expect(explorer.sources.skip(explorer.sources.length - 2), [
        ExplorerSource.thisFile,
        ExplorerSource.myGames,
      ]);
    });

    test('choosing one has it read its games, and says so meanwhile', () async {
      await choose(ExplorerSource.thisFile);
      expect(thisFile.wanted, greaterThan(0));
      expect(explorer.state, isA<ExplorerReading>());
      thisFile.state = const TreeReading(200, 400);
      thisFile.changed();
      final reading = explorer.state as ExplorerReading;
      expect((reading.done, reading.total), (200, 400));
      expect(myGames.wanted, 0, reason: 'only the one on show is read');
    });

    test('once read, every position is answered at once and no database is '
        'asked', () async {
      await choose(ExplorerSource.myGames);
      lichess.asked.clear();
      book.asked.clear();
      myGames
        ..state = const TreeBuilt()
        ..answer = startAnswer
        ..summary = '2 games';
      myGames.changed();
      expect(shown().rows.map((r) => r.san), ['e4', 'd4']);
      expect(shown().rows.first.inRepertoire, isTrue);
      expect(explorer.summary, '2 games');
      myGames.answer = afterE4Answer;
      fixture.session.forward();
      expect(shown().rows.single.san, 'e5', reason: 'no rest');
      expect(lichess.asked, isEmpty);
      expect(book.asked, isEmpty);
    });

    test('a position the games never reached has nothing', () async {
      await choose(ExplorerSource.thisFile);
      thisFile
        ..state = const TreeBuilt()
        ..answer = ExplorerAnswer.empty;
      thisFile.changed();
      expect(
        (explorer.state as ExplorerNothing).sentence,
        'No games found for this position.',
      );
    });

    test('a part that could not be read is a line beside the rows, and a '
        'tree that failed is a sentence whose Try again reads again', () async {
      await choose(ExplorerSource.myGames);
      myGames
        ..state = const TreeBuilt(notice: 'The database could not be read.')
        ..answer = startAnswer;
      myGames.changed();
      expect(explorer.notice, 'The database could not be read.');
      myGames
        ..state = const TreeFailed('Could not read your games.')
        ..answer = null;
      myGames.changed();
      expect(
        (explorer.state as ExplorerFailed).sentence,
        'Could not read your games.',
      );
      await explorer.retry();
      expect(myGames.forgotten, 1);
      expect(myGames.wanted, greaterThan(1));
    });

    test('a rebuild that failed leaves the rows it had, with the failure '
        'beside them', () async {
      await choose(ExplorerSource.thisFile);
      thisFile
        ..state = const TreeFailed('Could not read the games of this file.')
        ..answer = startAnswer;
      thisFile.changed();
      expect(shown().rows, hasLength(2));
      expect(explorer.notice, 'Could not read the games of this file.');
    });

    test('an empty tree says why', () async {
      await choose(ExplorerSource.myGames);
      myGames.state = const TreeEmpty('No games of yours are saved yet.');
      myGames.changed();
      expect(
        (explorer.state as ExplorerNothing).sentence,
        'No games of yours are saved yet.',
      );
    });

    test('a tree that changes while another source is chosen is not '
        'shown', () async {
      await start();
      thisFile
        ..state = const TreeBuilt()
        ..answer = afterE4Answer;
      thisFile.changed();
      expect(shown().rows.map((r) => r.san), ['e4', 'd4']);
    });
  });
}
