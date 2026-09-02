import 'dart:io';

import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/master_games/services/twic_repertoire_scan.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which of a pile of master games are worth opening, given the books you
/// actually play.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MyRepertoireSettings settings;
  late TwicRepertoireScanner scanner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('twic_scan_');
    settings = MyRepertoireSettings.forTest();
    scanner = TwicRepertoireScanner(
      deviations: GameDeviationService(settings: settings),
      settings: settings,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> writeChapter(String name, String content) async {
    await File('${tempDir.path}/$name').writeAsString(content);
  }

  /// A White book: the Najdorf with 6.Be3, and the Italian.
  const whiteBook = '''
// Color: White

[Event "Najdorf 6.Be3"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 *

[Event "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 *
''';

  var nextId = 1;
  MasterGame game(
    String movetext, {
    String white = 'A',
    String black = 'B',
    int whiteElo = 2600,
    int blackElo = 2600,
  }) => MasterGame(
    id: nextId++,
    twicIssue: 1660,
    event: 'Test',
    site: 'Testville',
    date: '2026.01.20',
    round: '1',
    white: white,
    black: black,
    result: '1-0',
    whiteElo: whiteElo,
    blackElo: blackElo,
    whiteFideId: null,
    blackFideId: null,
    eco: 'B90',
    plyCount: 20,
    movetext: movetext,
  );

  test('with no book designated the scan says so instead of failing', () async {
    final result = await scanner.scan(
      games: [game('1. e4 c5 2. Nf3 d6')],
      minPlies: 2,
    );
    expect(result.hasAnyBook, isFalse);
    expect(result.matches, isEmpty);
    expect(result.headline, contains('No repertoire is designated'));
  });

  test('separates a test of your move from running past your prep', () async {
    await writeChapter('White.pgn', whiteBook);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    // Followed the Najdorf line and then played 6...Ng4, which the book does
    // not cover an answer to at that point — it covers 6...e5.
    final tested = game(
      '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 Ng4',
      white: 'Carlsen,M',
    );
    // Went one move past where the prepared line stops.
    final pastPrep = game(
      '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 '
      '7. Nb3 Be6',
      white: 'So,W',
    );
    // Nothing to do with either book.
    final unrelated = game('1. d4 Nf6 2. c4 g6 3. Nc3 Bg7');

    final result = await scanner.scan(
      games: [tested, pastPrep, unrelated],
      minPlies: 4,
    );

    expect(result.hasWhiteBook, isTrue);
    expect(result.scanned, 3);
    expect(result.matches, hasLength(2));

    // Deepest agreement first: the one that reached move 7.
    expect(result.matches.first.game.id, pastPrep.id);
    expect(result.matches.first.ranPastYourPrep, isTrue);
    expect(result.matches.first.testedYourChoice, isFalse);
    expect(result.matches.first.report.chapterName, 'White');

    final second = result.matches[1];
    expect(second.game.id, tested.id);
    expect(second.testedYourChoice, isTrue);
    expect(second.report.playedSan, 'Ng4');
    expect(second.report.expectedSans, contains('e5'));

    expect(result.testedCount, 1);
    expect(result.pastPrepCount, 1);
    expect(result.headline, contains('2 of 3 games'));
  });

  test('a shallow brush with the book is not a match', () async {
    await writeChapter('White.pgn', whiteBook);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    // Two plies of agreement, then off.
    final result = await scanner.scan(
      games: [game('1. e4 c5 2. c3 Nf6')],
      minPlies: 6,
    );
    expect(result.matches, isEmpty);
    expect(result.headline, contains('None of these 1 games'));
  });

  test('the Black book is checked too, not just White', () async {
    const blackBook = '''
// Color: Black

[Event "Benko"]
[Result "*"]

1. d4 Nf6 2. c4 c5 3. d5 b5 4. cxb5 a6 *
''';
    await writeChapter('Black.pgn', blackBook);
    await settings.setPaths(white: false, paths: [tempDir.path]);

    final result = await scanner.scan(
      games: [game('1. d4 Nf6 2. c4 c5 3. d5 b5 4. cxb5 a6 5. bxa6')],
      minPlies: 6,
    );

    expect(result.hasBlackBook, isTrue);
    expect(result.matches, hasLength(1));
    expect(result.matches.first.bookIsWhite, isFalse);
    expect(result.matches.first.matchedPlies, 8);
  });

  test('equally deep games are ranked by strength', () async {
    await writeChapter('White.pgn', whiteBook);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    const line =
        '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 h6';
    final weak = game(line, whiteElo: 2400, blackElo: 2380);
    final strong = game(line, whiteElo: 2800, blackElo: 2790);

    final result = await scanner.scan(games: [weak, strong], minPlies: 4);
    expect(result.matches.map((m) => m.game.id), [strong.id, weak.id]);
  });

  test('a cancelled scan reports what it managed', () async {
    await writeChapter('White.pgn', whiteBook);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    var seen = 0;
    final games = [
      for (var i = 0; i < 10; i++)
        game('1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6'),
    ];
    final result = await scanner.scan(
      games: games,
      minPlies: 4,
      progressEvery: 2,
      onProgress: (done, _) => seen = done,
      isCancelled: () => seen >= 4,
    );

    expect(result.scanned, lessThan(games.length));
    expect(result.scanned, greaterThan(0));
  });

  test('a game with unreadable movetext is skipped, not fatal', () async {
    await writeChapter('White.pgn', whiteBook);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    final result = await scanner.scan(
      games: [game(''), game('1. e4 c5 2. Nf3 d6 3. d4 cxd4')],
      minPlies: 4,
    );
    expect(result.scanned, 2);
    expect(result.matches, hasLength(1));
  });
}
