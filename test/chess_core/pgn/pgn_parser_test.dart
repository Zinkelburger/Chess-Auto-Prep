import 'dart:math';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Object signature(PgnGame<PgnNodeData> game) {
  final values = <Object?>[];
  final pending = game.moves.children.reversed.toList();
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    values.add([
      node.data.san,
      node.data.comments,
      node.data.startingComments,
      node.data.nags,
      node.children.length,
    ]);
    pending.addAll(node.children.reversed);
  }
  return [game.headers, game.comments, values];
}

void main() {
  void agrees(String text) =>
      expect(signature(parsePgnGame(text)), signature(PgnGame.parsePgn(text)));
  test('headers, raw comments, variation order and NAGs match upstream', () {
    final comment = 'prose ' * 900;
    agrees(
      '[Event "Escaped \\"quote\\" and } { brackets"]\r\n\r\n'
      '{Introduction}\n1. e4 {$comment} \$1 ( {Before d4} 1. d4 {two\nparagraphs} d5? ) e5!! *',
    );
    final text = '1.e4{$comment}e5{[%cal Ge7e5] note}2.Nf3 *';
    agrees(text);
    final parsed = parsePgnGame(text);
    expect(
      parsed.moves.children.first.data.comments!.single,
      comment.trimRight(),
    );
    expect(parsed.moves.mainline().map((m) => m.san), ['e4', 'e5', 'Nf3']);
  });

  test(
    'inserted boundaries cannot create escape lines or end semicolon comments',
    () {
      final long = 'x' * 4200;
      for (final after in [
        '% e5',
        ' % e5',
        '; e5 {ignored}',
        '\$1 e5',
        '(1.d4) e5',
      ]) {
        agrees('1.e4 {$long}$after\n2.Nf3 *');
      }
      agrees('\ufeff% $long {ignored} 1.d4\n[Event "x"]\n\n1.e4 {$long}e5');
      agrees(
        '[Event "x"]\n\n1.e4 ;$long {ignored} e5\n% $long {ignored} d4\ne5 *',
      );
    },
  );

  test(
    'multiline, unclosed and non-nesting comments preserve parser behavior',
    () {
      final long = 'x' * 4200;
      agrees('1.e4 {$long\r\n% literal; { not nested\r\nend} e5 *');
      agrees('1.e4 {$long}e5 {unclosed\ncomment');
      agrees('[Event "${'x' * 4200} { ; \\" } "]\n\n1.e4 {a}e5');
    },
  );

  test(
    'large move numbers are labels, while standalone zero null moves survive',
    () {
      final parsed = parsePgnGame('10000. Nf3 10000... Nf6 10001. Ng1 0000 *');
      expect(parsed.moves.mainline().map((m) => m.san), [
        'Nf3',
        'Nf6',
        'Ng1',
        '--',
      ]);
      expect(
        parsePgnGame(
          '1. e4 {10000. is comment text}',
        ).moves.children.first.data.comments,
        ['10000. is comment text'],
      );
    },
  );

  test('empty header policy is forwarded', () {
    final parsed = parsePgnGame(
      '1.e4 {${'x' * 4200}}e5 *',
      initHeaders: PgnGame.emptyHeaders,
    );
    expect(parsed.headers, isEmpty);
    expect(parsed.moves.mainline().length, 2);
  });

  test(
    'generated annotated syntax preserves every parsed node and comment',
    () {
      final random = Random(731);
      for (var sample = 0; sample < 20; sample++) {
        final text = StringBuffer('[Event "Sample $sample"]\n\n');
        for (var i = 0; i < 120; i++) {
          text.write('${i + 1}.e4 {note $i ${'words ' * random.nextInt(35)}} ');
          switch (random.nextInt(5)) {
            case 0:
              text.write('( {intro} 1.d4 \$2 {sideline}) ');
            case 1:
              text.write('; ignored { brace } e5\r\n');
            case 2:
              text.write('\n% ignored { brace } d4\n');
            case 3:
              text.write('!? ');
            case 4:
              text.write('{line one\nline two} ');
          }
        }
        agrees(text.toString());
      }
    },
  );
}
