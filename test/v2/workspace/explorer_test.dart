import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
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

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late ScriptedExplorerApi lichess;
  late ScriptedBook book;
  late Explorer explorer;

  setUp(() async {
    fixture = await openSession(chapter);
    settings = SettingsStore();
    lichess = ScriptedExplorerApi();
    book = ScriptedBook(present: true);
  });

  tearDown(() {
    explorer.dispose();
    settings.dispose();
    fixture.dispose();
  });

  Future<void> start() async {
    explorer = explorerOver(
      fixture,
      settings: settings,
      lichess: lichess,
      book: book,
    );
    await pumpEventQueue();
  }

  ExplorerShown shown() => explorer.state as ExplorerShown;

  test('the table is the database\'s moves at the board, spelled for the '
      'position, ticked where the chapter plays them', () async {
    await start();
    final rows = shown().rows;
    expect(rows.map((r) => r.san), ['e4', 'd4']);
    expect(rows.first.label, '1.');
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
    expect(shown().rows.single.label, '1...');
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

  test('a listed game is fetched and kept as a file in the collections '
      'folder, to open at the ply on the board', () async {
    await start();
    fixture.session.forward();
    await pumpEventQueue();
    final game = startAnswer.games.single;
    final kept = await explorer.keepGame(game) as GameKept;
    expect(kept.ply, 1);
    expect(
      kept.ref.path,
      '$explorerCollections/explorer games/'
      'Carlsen, M - Nakamura, H 2024 (masters abcd1234).pgn',
    );
    expect(lichess.gamesAsked.single, ('abcd1234', true));
    expect(fixture.store.documents[kept.ref], isA<Opened>());
    // A second click on the same game opens the file already there.
    expect(await explorer.keepGame(game), isA<GameKept>());
    lichess.pgn = null;
    expect(
      (await explorer.keepGame(game) as GameNotKept).sentence,
      'Could not fetch that game.',
    );
  });

  test('a TWIC game comes from the book, and a name that cannot be a file '
      'name is made one', () async {
    await start();
    const game = ExplorerGame(
      id: '7',
      white: 'A/B: "C"',
      black: 'D?',
      result: '*',
    );
    expect(gameFileName(game, ExplorerSource.twic), 'A_B_ _C_ - D_ (twic 7)');
  });

  test('nothing open is idle', () async {
    await start();
    fixture.session.closed();
    expect(explorer.state, isA<ExplorerIdle>());
  });
}
