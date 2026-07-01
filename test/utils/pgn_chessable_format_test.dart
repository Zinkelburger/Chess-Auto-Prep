import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';

void main() {
  group('hasChessableFormatting', () {
    test('detects @@ markers', () {
      expect(hasChessableFormatting('@@HeaderStart@@Title@@HeaderEnd@@'), true);
      expect(hasChessableFormatting('@@StartBracket@@note@@EndBracket@@'), true);
    });

    test('detects double-space paragraphs in long text', () {
      final long = 'A' * 150 + '  ' + 'B' * 150 + '  ' + 'C' * 50;
      expect(hasChessableFormatting(long), true);
    });

    test('does NOT detect short comments with double-space', () {
      expect(hasChessableFormatting('Or  40.cxb5  c4!-+'), false);
    });

    test('does NOT trigger on normal comments', () {
      expect(hasChessableFormatting('A solid move.'), false);
    });
  });

  group('parseRichComment', () {
    test('parses header segments', () {
      final segs = parseRichComment(
        '@@HeaderStart@@How to improve@@HeaderEnd@@Some text.');
      expect(segs.length, 2);
      expect(segs[0].type, RichSegmentType.header);
      expect(segs[0].content, 'How to improve');
      expect(segs[1].type, RichSegmentType.text);
      expect(segs[1].content, contains('Some text'));
    });

    test('parses blockquote', () {
      final segs = parseRichComment(
        'Before. @@StartBlockQuote@@Quoted text.@@EndBlockQuote@@ After.');
      expect(segs.any((s) => s.type == RichSegmentType.blockQuote), true);
      final bq = segs.firstWhere((s) => s.type == RichSegmentType.blockQuote);
      expect(bq.content, 'Quoted text.');
    });

    test('parses bracket/editorial notes', () {
      final segs = parseRichComment(
        'The game @@StartBracket@@Alekhine@@EndBracket@@ was brilliant.');
      expect(segs.any((s) => s.type == RichSegmentType.bracket), true);
      final br = segs.firstWhere((s) => s.type == RichSegmentType.bracket);
      expect(br.content, 'Alekhine');
    });

    test('parses square brackets same as bracket', () {
      final segs = parseRichComment(
        'Black @@StartSquare@@Editor@@EndSquare@@ played.');
      expect(segs.any((s) => s.type == RichSegmentType.bracket), true);
    });

    test('parses FEN segments', () {
      final fen = '8/p3np1p/6p1/1N6/1Pk5/7P/P4PP1/6K1 w - - 3 8';
      final segs = parseRichComment(
        'Position: @@StartFEN@@$fen@@EndFEN@@ continues.');
      expect(segs.any((s) => s.type == RichSegmentType.fen), true);
      final fenSeg = segs.firstWhere((s) => s.type == RichSegmentType.fen);
      expect(fenSeg.content, fen);
    });

    test('parses link segments', () {
      final segs = parseRichComment(
        'Visit @@LinkStart@@www.ruchess.ru@@LinkEnd@@ for info.');
      expect(segs.any((s) => s.type == RichSegmentType.link), true);
      final link = segs.firstWhere((s) => s.type == RichSegmentType.link);
      expect(link.content, 'www.ruchess.ru');
    });

    test('handles double-space paragraph breaks in text segments', () {
      final segs = parseRichComment(
        'First paragraph about chess.  Second paragraph about endgames.');
      expect(segs.length, 1);
      expect(segs[0].type, RichSegmentType.text);
      expect(segs[0].content, contains('\n'));
      final parts = segs[0].content.split('\n');
      expect(parts.length, 2);
      expect(parts[0], 'First paragraph about chess.');
      expect(parts[1], 'Second paragraph about endgames.');
    });

    test('handles mixed markers and text', () {
      final raw = '@@HeaderStart@@Title@@HeaderEnd@@Intro text.  '
          '@@StartBlockQuote@@A quote.@@EndBlockQuote@@ '
          'Then @@StartBracket@@note@@EndBracket@@ end.';
      final segs = parseRichComment(raw);
      expect(segs.any((s) => s.type == RichSegmentType.header), true);
      expect(segs.any((s) => s.type == RichSegmentType.blockQuote), true);
      expect(segs.any((s) => s.type == RichSegmentType.bracket), true);
    });
  });

  group('parseCommentTokens', () {
    test('classifies a simple inline alternative line', () {
      final tokens =
          parseCommentTokens('Or  40.cxb5  c4!-+  , winning the pawn ending.');
      expect(tokens[0], isA<CommentProse>());
      expect((tokens[0] as CommentProse).text, 'Or');

      expect(tokens[1], isA<CommentMove>());
      final cxb5 = tokens[1] as CommentMove;
      expect(cxb5.san, 'cxb5');
      expect(cxb5.moveNumber, 40);
      expect(cxb5.isWhite, true);

      final c4 = tokens[2] as CommentMove;
      expect(c4.san, 'c4');
      expect(c4.moveNumber, 40);
      expect(c4.isWhite, false); // derived: Black's 40th
      expect(c4.runId, cxb5.runId); // same contiguous run

      expect(tokens[3], isA<CommentProse>());
    });

    test('keeps a line together through interspersed prose', () {
      final tokens = parseCommentTokens(
          'Editor\'s Note:  42...Kc3?  is a draw:  43.Rxc4+  Kxb3  44.Rxc5  Ra7');
      final moves = tokens.whereType<CommentMove>().toList();

      // 42...Kc3? -> Black move 42.
      expect(moves[0].san, 'Kc3');
      expect(moves[0].moveNumber, 42);
      expect(moves[0].isWhite, false);

      // 43.Rxc4+ is the natural successor, so it stays in the SAME line even
      // though "is a draw:" prose sits between them.
      expect(moves[1].san, 'Rxc4');
      expect(moves[1].moveNumber, 43);
      expect(moves[1].isWhite, true);
      expect(moves[1].runId, moves[0].runId);

      // Kxb3 derived as Black's 43rd, same run.
      expect(moves[2].san, 'Kxb3');
      expect(moves[2].moveNumber, 43);
      expect(moves[2].isWhite, false);
      expect(moves[2].runId, moves[0].runId);

      // 44.Rxc5 explicit White 44, still same run.
      expect(moves[3].moveNumber, 44);
      expect(moves[3].isWhite, true);
      expect(moves[3].runId, moves[0].runId);
    });

    test('starts a new line when analysis jumps back to a different move', () {
      final tokens = parseCommentTokens(
          '42...Kc3?  43.Rxc4+  Kxb3  However  42...Ke3  43.Rxc4  Ra5');
      final moves = tokens.whereType<CommentMove>().toList();
      // First line: 42...Kc3 43.Rxc4 Kxb3
      final line1 = moves[0].runId;
      expect(moves[1].runId, line1);
      expect(moves[2].runId, line1);
      // Jump back to 42...Ke3 starts a new line.
      expect(moves[3].san, 'Ke3');
      expect(moves[3].moveNumber, 42);
      expect(moves[3].runId, isNot(line1));
      expect(moves[4].runId, moves[3].runId);
      expect(moves[5].runId, moves[3].runId);
    });

    test('strips check/annotation/eval glyphs from playable san', () {
      final tokens = parseCommentTokens('48.Rb1+!=  47.Rxc5  Rc3!-+');
      final moves = tokens.whereType<CommentMove>().toList();
      expect(moves[0].san, 'Rb1'); // + ! = stripped
      expect(moves[0].display, '48.Rb1+!=');
      expect(moves.last.san, 'Rc3'); // ! -+ stripped
    });

    test('does not treat prose words as moves', () {
      final tokens = parseCommentTokens('is a draw:  also wins, for example,');
      expect(tokens.every((t) => t is CommentProse), true);
    });

    test('castling is recognized', () {
      final tokens = parseCommentTokens('12.O-O  O-O-O');
      final moves = tokens.whereType<CommentMove>().toList();
      expect(moves[0].san, 'O-O');
      expect(moves[1].san, 'O-O-O');
    });
  });

  group('parseCommentTokens — bare FEN anchors (book PGNs)', () {
    const fen = 'r1bqkbnr/pp1ppp1p/2n3p1/8/3NP3/8/PPP2PPP/RNBQKB1R w KQkq - 1 5';

    test('hides the FEN and anchors the following run to it', () {
      final tokens = parseCommentTokens(
          'The next part is about more normal Dragon play after $fen\n'
          '5.Nc3\nBg7\n6.Be3');

      // FEN itself is never emitted as a token.
      expect(tokens.whereType<CommentProse>().any((p) => p.text.contains('/')),
          false);
      // Surrounding prose survives.
      expect(tokens.first, isA<CommentProse>());
      expect((tokens.first as CommentProse).text, contains('Dragon play after'));

      final moves = tokens.whereType<CommentMove>().toList();
      expect(moves.map((m) => m.san), ['Nc3', 'Bg7', 'Be3']);
      // Every move of the run carries the FEN anchor.
      expect(moves.every((m) => m.anchorFen == fen), true);
      // And they form one contiguous run.
      expect(moves.map((m) => m.runId).toSet().length, 1);
      // Numbering aligns with the FEN (White to move, fullmove 5).
      expect(moves[0].moveNumber, 5);
      expect(moves[0].isWhite, true);
      expect(moves[1].isWhite, false); // Bg7 = Black's 5th
    });

    test('an unnumbered first move is seeded from the FEN side/number', () {
      final tokens = parseCommentTokens('special attention to $fen\nNc3');
      final move = tokens.whereType<CommentMove>().single;
      expect(move.san, 'Nc3');
      expect(move.moveNumber, 5);
      expect(move.isWhite, true);
      expect(move.anchorFen, fen);
    });

    test('non-FEN inline lines keep a null anchor', () {
      final tokens = parseCommentTokens('Or  40.cxb5  c4!-+  , winning.');
      expect(
          tokens.whereType<CommentMove>().every((m) => m.anchorFen == null),
          true);
    });

    test('an invalid FEN-looking token stays as prose', () {
      // 9 ranks — not a legal FEN, must not be swallowed.
      const bad = 'r1bqkbnr/pp/pp/pp/pp/pp/pp/pp/pp w KQkq - 1 5';
      final tokens = parseCommentTokens('see $bad here');
      expect(tokens.whereType<CommentProse>().any((p) => p.text.contains('r1bqkbnr')),
          true);
      expect(tokens.whereType<CommentMove>().every((m) => m.anchorFen == null),
          true);
    });
  });

  group('filterDisplayComment', () {
    test('strips @@ markers but keeps content', () {
      final result = filterDisplayComment(
        '@@StartBracket@@Alekhine@@EndBracket@@ played well.');
      expect(result, 'Alekhine played well.');
    });

    test('strips all marker types', () {
      final result = filterDisplayComment(
        '@@HeaderStart@@Title@@HeaderEnd@@ @@StartFEN@@fen@@EndFEN@@');
      expect(result, 'Title fen');
    });
  });
}
