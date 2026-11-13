// The Analysis tab's own board: a copy of the game on screen to try things
// on, kept per game, which never writes the file it came from.
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/document/collection_analysis.dart';
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
}
