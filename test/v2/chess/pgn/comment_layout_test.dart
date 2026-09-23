import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/comment_layout.dart';
import 'package:flutter_test/flutter_test.dart';

// After 1. d4 Nf6 2. c4 g6, where the King's Indian course opens.
const _kid = Fen(
  'rnbqkb1r/pppppp1p/5np1/8/2PP4/8/PP2PPPP/RNBQKBNR w KQkq - 0 3',
);

void main() {
  const after1e4e5 = Fen(
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
  );
  const fourPawnsFen =
      'rnbqk2r/ppp1ppbp/3p1np1/8/2PPP3/2N5/PP3PPP/R1BQKBNR w KQkq - 0 5';

  test('is many paragraphs, not one', () {
    expect(_paragraphs().length, greaterThan(5));
    expect(
      _paragraphs().first.spans.first,
      isA<Words>().having((w) => w.text, 'text', startsWith('Wel@ome back!')),
    );
  });

  test('shows the diagrams even where their fences are garbled', () {
    final diagrams = _kidIntro().whereType<Diagram>().map((d) => d.fen.value);
    expect(diagrams, contains(fourPawnsFen));
    expect(diagrams.length, 4);
    expect(diagrams.last, endsWith('R1BQKBNR w KQkq - 2 4'));
  });

  test('leaves no marker or fence in the words', () {
    final words = _paragraphs()
        .expand((p) => p.spans)
        .whereType<Words>()
        .map((w) => w.text)
        .join();
    expect(words, isNot(contains('îî')));
    expect(words, isNot(contains('StartFEN')));
    expect(words, isNot(contains('EndFEN')));
    expect(words, isNot(contains('â€')));
    expect(words, contains('• The Hungarian Attack:'));
  });

  test('the first line plays from the comment\'s own position', () {
    final run = _runOf('3. Nc3 Bg7 4. e4 d6 5. Be2');
    expect(run.moves.map((m) => m.uci), [
      'b1c3',
      'f8g7',
      'e2e4',
      'd7d6',
      'f1e2',
    ]);
    expect(run.fromComment?.length, 5);
    expect(
      run.moves.last.after.value,
      startsWith('rnbqk2r/ppp1ppbp/3p1np1/8/2PPP3/2N5/PP2BPPP/R1BQK1NR b'),
    );
  });

  test('an alternative fifth move branches from the earlier line', () {
    final run = _runOf('5. Bg5');
    expect(run.fromComment?.map((m) => m.san), [
      'Nc3',
      'Bg7',
      'e4',
      'd6',
      'Bg5',
    ]);
    final reply = _runOf('5... c5');
    expect(reply.fromComment?.map((m) => m.san), [
      'Nc3',
      'Bg7',
      'e4',
      'd6',
      'Bg5',
      'c5',
    ]);
  });

  test('a line after a diagram plays from the diagram', () {
    final run = _runOf('5. f4');
    expect(run.fromComment, isNull);
    expect(run.moves.single.uci, 'f2f4');
    final smyslov = _runOf('4. Nf3 O-O 5. Bg5');
    expect(smyslov.fromComment, isNull);
  });

  test('a later line finds the comment position again through the chain', () {
    final fianchetto = _runOf('3. g3');
    expect(fianchetto.fromComment?.map((m) => m.san), ['g3']);
    final setup = _runOf('3... Bg7 4. Bg2 O-O 5. Nc3 d6 6. Nf3 c5');
    expect(setup.fromComment?.length, 8);
    expect(setup.fromComment?.first.san, 'g3');
  });

  test('moves that fit no position stay words', () {
    expect(_runs().map(_text), isNot(contains('1. e4')));
    expect(_runs().map(_text), isNot(contains('1. b3')));
    expect(_runs().map(_text), isNot(contains('1... Nf6')));
    final words = _paragraphs().expand((p) => p.spans).whereType<Words>();
    expect(words.map((w) => w.text).join(), contains('except 1.e4.'));
  });

  test('a short comment keeps its double space inside one paragraph', () {
    final blocks = layoutComment('Good move  2.Nf3 Nc6', at: after1e4e5);
    expect(blocks, hasLength(1));
    final spans = (blocks.single as Paragraph).spans;
    expect(spans, hasLength(2));
    expect((spans.first as Words).text, 'Good move ');
    final run = spans.last as MoveRun;
    expect(run.moves.map((m) => m.text), ['2. Nf3', 'Nc6']);
    expect(run.fromComment?.map((m) => m.uci), ['g1f3', 'b8c6']);
  });

  test('machine tokens never reach the reader', () {
    final blocks = layoutComment('[%eval 0.3] Best.', at: Fen.initial);
    expect(blocks, hasLength(1));
    final spans = (blocks.single as Paragraph).spans;
    expect(spans, hasLength(1));
    expect((spans.single as Words).text, 'Best.');
    expect(layoutComment('[%clk 0:01:00]', at: Fen.initial), isEmpty);
  });

  test('an illegal or misnumbered line stays words', () {
    for (final comment in ['3.Kxe8', '1.Kxe8 wins', '2.Nf3 first']) {
      final blocks = layoutComment(comment, at: Fen.initial);
      final spans = (blocks.single as Paragraph).spans;
      expect(spans, hasLength(1), reason: comment);
      expect((spans.single as Words).text, comment);
    }
  });

  test('a line that goes wrong keeps its legal start', () {
    final blocks = layoutComment('1.e4 e5 2.Kxe8 Nf6', at: Fen.initial);
    final spans = (blocks.single as Paragraph).spans;
    expect(spans, hasLength(2));
    expect((spans.first as MoveRun).moves.map((m) => m.san), ['e4', 'e5']);
    expect((spans.last as Words).text, ' 2.Kxe8 Nf6');
  });

  test('punctuation glued to a move stays outside the run', () {
    final blocks = layoutComment(
      'Then 1.e4. Or 1. d4, or 1.c4',
      at: Fen.initial,
    );
    final spans = (blocks.single as Paragraph).spans;
    expect(spans.whereType<MoveRun>().length, 3);
    expect(spans.whereType<Words>().map((w) => w.text), [
      'Then ',
      '. Or ',
      ', or ',
    ]);
  });

  test('a blank line breaks a paragraph and a single newline does not', () {
    expect(
      layoutComment('One.\n\nTwo.\r\n  \r\nThree.', at: Fen.initial),
      hasLength(3),
    );
    final joined = layoutComment('One.\nTwo.', at: Fen.initial);
    expect(joined, hasLength(1));
    expect(
      ((joined.single as Paragraph).spans.single as Words).text,
      'One. Two.',
    );
  });

  test('a long comment breaks paragraphs at double spaces and bullets', () {
    final filler = 'word ' * 70;
    final blocks = layoutComment(
      'First.  Second. • Third $filler',
      at: Fen.initial,
    );
    expect(blocks, hasLength(3));
    expect(((blocks[1] as Paragraph).spans.single as Words).text, 'Second.');
    expect(
      ((blocks[2] as Paragraph).spans.single as Words).text,
      startsWith('• Third'),
    );
  });

  test('headings, quotes, brackets and links', () {
    final blocks = layoutComment(
      '@@HeaderStart@@Plan@@HeaderEnd@@ text @@StartBracket@@see part '
      'one@@EndBracket@@ @@StartSquare@@1@@EndSquare@@ '
      '@@LinkStart@@https://example.com@@LinkEnd@@ '
      '@@StartBlockQuote@@Quoted 1.e4@@EndBlockQuote@@',
      at: Fen.initial,
    );
    expect(blocks, hasLength(3));
    expect((blocks[0] as Heading).text, 'Plan');
    expect(
      ((blocks[1] as Paragraph).spans.single as Words).text,
      'text (see part one) [1] https://example.com',
    );
    final quote = blocks[2] as Quote;
    expect((quote.spans.first as Words).text, 'Quoted ');
    expect((quote.spans.last as MoveRun).moves.single.san, 'e4');
  });

  test('a diagram in FEN markers, even hard-wrapped, splits the paragraph', () {
    final blocks = layoutComment(
      'Before îîStartFENîîrnbqk2r/ppp1ppbp/3p1np1/8/2PPP3/2N5/\r\n'
      'PP3PPP/R1BQKBNR w KQkq\r\n- 0 5îîEndFENîî 5.f4 after',
      at: Fen.initial,
    );
    expect(blocks.map((b) => b.runtimeType), [Paragraph, Diagram, Paragraph]);
    expect((blocks[1] as Diagram).fen.value, fourPawnsFen);
    final run = (blocks[2] as Paragraph).spans.first as MoveRun;
    expect(run.moves.single.uci, 'f2f4');
    expect(run.fromComment, isNull);
  });

  test('a bare FEN in prose is a diagram too, and a broken one is not', () {
    final blocks = layoutComment(
      'See $fourPawnsFen and then 5.Be2 too',
      at: Fen.initial,
    );
    expect(blocks.map((b) => b.runtimeType), [Paragraph, Diagram, Paragraph]);
    expect(((blocks[2] as Paragraph).spans.first as Words).text, 'and then ');
    expect(
      layoutComment('@@StartFEN@@not a fen@@EndFEN@@ words', at: Fen.initial),
      [isA<Paragraph>()],
    );
  });

  test('a board the FEN parser throws an error on is words, not a crash', () {
    // `.` counts as minus two squares, and the board parser answers with an
    // error rather than an exception.
    final blocks = layoutComment(
      'See @@StartFEN@@8/8/8/8/8/8/8/.N w - - 0 1@@EndFEN@@ here',
      at: Fen.initial,
    );
    expect(blocks.whereType<Diagram>(), isEmpty);
    expect(blocks, isNotEmpty);
  });

  test('a number too long to be a move number is words', () {
    final blocks = layoutComment(
      'Not 123456789012345678901.e4 but 1.e4',
      at: Fen.initial,
    );
    final spans = (blocks.single as Paragraph).spans;
    expect((spans.first as Words).text, 'Not 123456789012345678901.e4 but ');
    expect((spans.last as MoveRun).moves.single.san, 'e4');
  });

  test('mojibake is read as the punctuation it was', () {
    final blocks = layoutComment(
      'Whiteâ€™s â€œplanâ€ â€“ done',
      at: Fen.initial,
    );
    expect(
      ((blocks.single as Paragraph).spans.single as Words).text,
      'White’s “plan” – done',
    );
  });
}

/// The Introduction comment of the King's Indian course, laid out from the
/// position it is written on.
List<CommentBlock> _kidIntro() => layoutComment(
  File('test/fixtures/v2_comments/kid_intro_comment.txt').readAsStringSync(),
  at: _kid,
);

List<Paragraph> _paragraphs() => _kidIntro().whereType<Paragraph>().toList();

List<MoveRun> _runs() =>
    _paragraphs().expand((p) => p.spans).whereType<MoveRun>().toList();

String _text(MoveRun run) => run.moves.map((m) => m.text).join(' ');

MoveRun _runOf(String printed) =>
    _runs().firstWhere((run) => _text(run) == printed);
