// The Analysis tab's own board: a copy of the game on screen to try things
// on, kept per game, which never writes the file it came from.
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/repertoire_import.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/document/collection_analysis.dart';
import 'package:chess_auto_prep/workspace/document/document_actions.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late EngineAnalysis sourceEngine;
  late CollectionAnalysis analysis;
  var disposed = false;

  Future<EngineStart> noEngine() async => const StartFailed('no engine here');

  setUp(() async {
    disposed = false;
    fixture = await openSession(blackChapter);
    sourceEngine = EngineAnalysis(fixture.session, noEngine);
    analysis = CollectionAnalysis(
      source: fixture.session,
      store: fixture.store,
      launch: noEngine,
      sourceEngine: sourceEngine,
      multiPv: 1,
    );
  });
  tearDown(() {
    if (!disposed) analysis.dispose();
    sourceEngine.dispose();
    fixture.dispose();
  });

  List<String> mainLine() => [
    for (final move in analysis.session.tree!.mainLine) move.san,
  ];

  test('shows a copy of the game and is the board while it is up', () async {
    var told = 0;
    analysis.addListener(() => told++);
    expect(await analysis.show(), isTrue);
    expect(analysis.active, isTrue);
    expect(mainLine(), [
      for (final move in fixture.session.tree!.mainLine) move.san,
    ]);
    final before = told;
    analysis.hide();
    expect(analysis.active, isFalse);
    expect(told, greaterThan(before));
  });

  test('is not shown while part of the game is hidden', () async {
    fixture.session.showOnlyTo(NodePath.of([0]));
    expect(await analysis.show(), isFalse);
    expect(analysis.active, isFalse);
  });

  test('of two shows asked at once, only the later one shows', () async {
    final first = analysis.show();
    final second = analysis.show();
    expect(await first, isFalse);
    expect(await second, isTrue);
  });

  test('plays a comment line on the board as far as it was read, the first '
      'time only', () async {
    final from = NodePath.of([0]);
    final line = pvMoves(fixture.session.tree!.fenAt(from), [
      'g1f3',
      'e7e6',
      'd2d4',
    ]);
    fixture.session.cursor.showCommentLine(from, line, 1);
    expect(await analysis.show(), isTrue);
    final played = analysis.session.tree!.lineTo(analysis.session.cursor.value);
    expect(played.map((m) => m.uci).skip(1), ['g1f3', 'e7e6']);
    analysis.hide();
    expect(await analysis.show(), isTrue);
    final again = analysis.session.tree!.lineTo(analysis.session.cursor.value);
    expect(again.map((m) => m.uci).skip(1), ['g1f3', 'e7e6']);
  });

  test('a pasted game replaces the board, and is there on return', () async {
    expect(await analysis.show(), isTrue);
    expect(await analysis.paste('1. d4 d5 2. c4 *'), isNull);
    expect(mainLine(), ['d4', 'd5', 'c4']);
    analysis.hide();
    expect(await analysis.show(), isTrue);
    expect(mainLine(), ['d4', 'd5', 'c4']);
  });

  test('a large paste cannot replace a later paste', () async {
    expect(await analysis.show(), isTrue);
    final first = analysis.paste(blackChapter.padRight(readOffThreadFrom));
    expect(await analysis.paste('1. Nf3 *'), isNull);
    await first;
    expect(mainLine(), ['Nf3']);
  });

  test('copying and pasting a scratch game keeps a new variation', () async {
    await fixture.session.open(fixture.ref, game: 0);
    fixture.session.cursor.toStart();
    expect(await analysis.show(), isTrue);
    final scratch = analysis.session;
    Iterable<String> replies() =>
        scratch.tree!.children.map((move) => move.san);

    scratch.playMove('e7e5');
    expect(replies(), ['c5', 'e5']);
    final copied = gameText(scratch);
    final imported = readImport(copied, created: DateTime(2026));
    expect((imported as ImportedChapters).side, Side.black);
    expect(await analysis.paste(copied), isNull);
    expect(replies(), ['c5', 'e5']);
  });

  test(
    'a copied repertoire keeps every record on the analysis board',
    () async {
      final text = blackChapter.replaceFirst(
        '1... c5 2. Nc3',
        '1... c5 {A different note on the same move} 2. Nc3',
      );
      fixture.externalEdit(text);
      await fixture.session.open(fixture.ref);
      expect(await analysis.show(), isTrue);
      expect(gameText(analysis.session), text);

      expect(await analysis.paste(gameText(fixture.session)), isNull);
      expect(gameText(analysis.session), text);
      expect(analysis.session.chapter!.skippedGames, 1);
      expect(
        analysis.session.tree!.children.single.children.map((n) => n.san),
        ['Nf3', 'Nc3'],
      );
    },
  );

  test(
    'a scratch branch preserves the unread part of its source game',
    () async {
      const game = '[Event "Partial"]\n\n1. d4 e6 -- 2. c4 {keep this} *';
      fixture.externalEdit(game);
      await fixture.session.open(fixture.ref, game: 0);
      expect(await analysis.show(), isTrue);
      final scratch = analysis.session;
      scratch
        ..cursor.toStart()
        ..playMove('e2e4');

      final copied = gameText(scratch);
      expect(copied, contains(game));
      expect(await analysis.paste(copied), isNull);
      expect(scratch.chapter!.lines.first.text, game);
      expect(scratch.chapter!.protectedGames, 1);
      expect(scratch.tree!.children.map((move) => move.san), ['d4', 'e4']);
    },
  );

  test('once taken down, it shows nothing', () async {
    analysis.dispose();
    disposed = true;
    expect(await analysis.show(), isFalse);
  });

  test('a board put in place is kept for the game', () async {
    expect(await analysis.show(), isTrue);
    await analysis.put(
      parseChapter(name: 'Board', text: '[Event "?"]\n\n1. Nf3 *\n'),
    );
    analysis.hide();
    expect(await analysis.show(), isTrue);
    expect(mainLine(), ['Nf3']);
  });

  test(
    'a game changed on screen before it was ever shown changes nothing',
    () async {
      await fixture.session.open(chapterRef('KID', 'Other'));
      analysis.hide();
      expect(analysis.active, isFalse);
    },
  );
}
