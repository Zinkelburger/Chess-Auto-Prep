import 'package:chess_auto_prep/chess/audit/chapter_audit.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart' show pathOfSans;
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

const text = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 *

[Event "Sicilian"]
[Result "*"]

1. e4 c5 2. Nf3 Nc6 3. d4 *

[Event "Transposed"]
[Result "*"]

1. Nf3 Nc6 2. e4 e5 3. Bb5 a6 4. Ba4 *
''';

String sanOf(Fen fen, String uci) => pvMoves(fen, [uci]).single.san;

void main() {
  late Chapter chapter;
  late List<AuditPosition> positions;

  setUp(() async {
    chapter = await readChapter(name: 'Main', text: text);
    positions = auditPositions(chapter.tree, Side.white);
  });

  AuditPosition at(String sans) =>
      positions.firstWhere((position) => position.sans.join(' ') == sans);

  test('positions are the ones the chapter plays from, each move asked '
      'about once, found by the shortest way, ours and theirs told apart', () {
    expect(positions.first.sans, isEmpty);
    expect(positions.first.ours, isTrue);
    expect(at('e4').ours, isFalse);
    expect(at('e4').moves.map((m) => m.san), ['e5', 'c5']);
    expect(at('e4 e5 Nf3 Nc6').moves.map((m) => m.san), ['Bc4']);
    expect(
      positions.any((p) => p.sans.join(' ') == 'e4 e5 Nf3 Nc6 Bc4'),
      isFalse,
      reason: 'the chapter stops there: nothing of its own to check',
    );
    expect(at('e4 c5').path, NodePath.of([0, 1]));
  });

  test('a position reached again by another order is asked about once, '
      'but a move first played there is judged where it is played and '
      'what follows it is walked', () {
    // 1.Nf3 Nc6 2.e4 e5 reaches the Open game's position after 2.Nf3 Nc6.
    final repeat = at('Nf3 Nc6 e4 e5');
    expect(repeat.fen.position, at('e4 e5 Nf3 Nc6').fen.position);
    expect(repeat.moves.map((m) => m.san), ['Bb5']);
    expect(repeat.path, pathOfSans(chapter.tree, repeat.sans));
    expect(chapter.tree.nodeAt(repeat.path)!.children.single.san, 'Bb5');
    expect(at('Nf3 Nc6 e4 e5 Bb5 a6').ours, isTrue);
    final asked = <String>{};
    for (final position in positions) {
      for (final move in position.moves) {
        expect(
          asked.add('${position.fen.position}|${move.uci}'),
          isTrue,
          reason: 'no move is judged twice',
        );
      }
    }

    final weak = weakMoves(
      repeat,
      lines: const [(uci: 'f1c4', cp: 50), (uci: 'f1b5', cp: -80)],
      scoreAfter: const {},
      reach: null,
      sanOf: (uci) => sanOf(repeat.fen, uci),
    ).single;
    expect(weak.san, 'Bb5');
    expect(weak.sans, ['Nf3', 'Nc6', 'e4', 'e5']);
  });

  test('a transposition whose moves were all met before is still walked '
      'past, to what only it plays further on', () async {
    final tree = (await readChapter(
      name: 'Deeper',
      text: '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 *

[Event "Transposed"]
[Result "*"]

1. Nf3 Nc6 2. e4 e5 3. Bc4 Nf6 4. Ng5 *
''',
    )).tree;
    final found = auditPositions(tree, Side.white);
    final sans = found.map((p) => p.sans.join(' ')).toList();
    expect(sans, isNot(contains('Nf3 Nc6 e4 e5')), reason: 'Bc4 met before');
    expect(sans, contains('Nf3 Nc6 e4 e5 Bc4 Nf6'));
  });

  test('a move of ours that loses is weak: a mistake from 100 cp, an '
      'inaccuracy from 40, nothing below', () {
    final sicilian = at('e4 c5 Nf3 Nc6');
    List<WeakMove> judged(List<ScoredMove> lines, [Map<String, int>? after]) =>
        weakMoves(
          sicilian,
          lines: lines,
          scoreAfter: after ?? const {},
          reach: 0.3,
          sanOf: (uci) => sanOf(sicilian.fen, uci),
        );

    expect(
      judged([(uci: 'd2d4', cp: 40), (uci: 'f1b5', cp: 35)]),
      isEmpty,
      reason: 'the chapter plays the best move',
    );
    final inaccuracy = judged([
      (uci: 'f1b5', cp: 60),
      (uci: 'd2d4', cp: 15),
    ]).single;
    expect(inaccuracy.lossCp, 45);
    expect(inaccuracy.mistake, isFalse);
    expect(inaccuracy.bestSan, 'Bb5');
    expect(inaccuracy.san, 'd4');
    final mistake = judged(
      [(uci: 'f1b5', cp: 60), (uci: 'c2c3', cp: 50)],
      {'d2d4': -70},
    ).single;
    expect(mistake.lossCp, 130, reason: 'scored after the move, not listed');
    expect(mistake.mistake, isTrue);
    expect(
      judged([(uci: 'f1b5', cp: 60)]),
      isEmpty,
      reason: 'a move nothing scored is not judged',
    );
  });

  test('a mate is never a loss in centipawns: missing one or walking into '
      'one is a mistake of its own, and a slower mate is no mistake', () {
    final sicilian = at('e4 c5 Nf3 Nc6');
    List<WeakMove> judged(List<ScoredMove> lines) => weakMoves(
      sicilian,
      lines: lines,
      scoreAfter: const {},
      reach: null,
      sanOf: (uci) => sanOf(sicilian.fen, uci),
    );

    final misses = judged([
      (uci: 'f1b5', cp: 9997),
      (uci: 'd2d4', cp: 40),
    ]).single;
    expect(misses.missesMate, isTrue);
    expect(misses.lossCp, isNull, reason: 'not 99.57 pawns');
    expect(misses.mistake, isTrue);
    final allows = judged([
      (uci: 'f1b5', cp: 20),
      (uci: 'd2d4', cp: -9998),
    ]).single;
    expect(allows.allowsMate, isTrue);
    expect(allows.lossCp, isNull);
    expect(
      judged([(uci: 'f1b5', cp: 9998), (uci: 'd2d4', cp: 9995)]),
      isEmpty,
      reason: 'a mate is a mate',
    );
    expect(
      judged([(uci: 'f1b5', cp: -9990), (uci: 'd2d4', cp: -9995)]),
      isEmpty,
      reason: 'lost either way',
    );
  });

  test('a good reply the chapter does not play, the Replies tab does not '
      'list and that leads nowhere the repertoire answers is a strong '
      'reply', () {
    final afterE4 = at('e4');
    final afterE6 = pvMoves(afterE4.fen, ['e7e6']).single.after;
    List<StrongReply> judged(
      List<ScoredMove> lines, {
      Map<String, double>? shares,
      Set<String> answered = const {},
      Set<String> gaps = const {},
    }) => strongReplies(
      afterE4,
      lines: lines,
      shares: shares,
      answered: answered,
      gaps: gaps,
      leadsInto: (uci) => pvMoves(afterE4.fen, [uci]).firstOrNull?.after,
      sanOf: (uci) => sanOf(afterE4.fen, uci),
      reach: 1,
      fromChessDb: false,
    );

    const lines = [
      (uci: 'e7e5', cp: -30),
      (uci: 'e7e6', cp: -40),
      (uci: 'c7c6', cp: -45),
      (uci: 'd7d5', cp: -90),
    ];
    final found = judged(
      lines,
      shares: {'e7e5': 0.5, 'e7e6': 0.05, 'c7c6': 0.2},
      gaps: {'c7c6'},
    );
    expect(found.map((r) => r.san), [
      'e6',
    ], reason: 'e5 is played, c6 is a gap on the Replies tab, d5 too weak');
    expect(found.single.behindCp, 10);
    expect(found.single.share, 0.05);
    expect(judged(lines, answered: {afterE6.position}).map((r) => r.san), [
      'c6',
    ], reason: 'a reply another chapter answers is answered');
    expect(
      judged([(uci: 'e7e6', cp: -30)]).single.share,
      isNull,
      reason: 'with no model every good reply is named',
    );
  });

  test('beside a mate only another mate is strong, and none where every '
      'reply is mated', () {
    final afterE4 = at('e4');
    List<StrongReply> judged(List<ScoredMove> lines) => strongReplies(
      afterE4,
      lines: lines,
      shares: null,
      answered: const {},
      gaps: const {},
      leadsInto: (uci) => pvMoves(afterE4.fen, [uci]).firstOrNull?.after,
      sanOf: (uci) => sanOf(afterE4.fen, uci),
      reach: null,
      fromChessDb: false,
    );

    final mates = judged([
      (uci: 'g8f6', cp: 9990),
      (uci: 'e7e6', cp: 9985),
      (uci: 'c7c6', cp: 60),
    ]);
    expect(mates.map((r) => r.san), ['Nf6', 'e6']);
    expect(mates.every((r) => r.mates && r.behindCp == null), isTrue);
    expect(
      judged([(uci: 'e7e6', cp: -9990), (uci: 'c7c6', cp: -9992)]),
      isEmpty,
    );
  });

  test('keys say where, what and which kind, so a rerun finds the same '
      'finding', () {
    final position = at('e4');
    final reply = strongReplies(
      position,
      lines: const [(uci: 'e7e6', cp: 0)],
      shares: null,
      answered: const {},
      gaps: const {},
      leadsInto: (uci) => pvMoves(position.fen, [uci]).firstOrNull?.after,
      sanOf: (uci) => uci,
      reach: 1,
      fromChessDb: false,
    ).single;
    expect(reply.key, 'reply|${position.fen.position}|e7e6');
  });
}
