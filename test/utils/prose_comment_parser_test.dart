import 'package:chess_auto_prep/utils/prose_comment_parser.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const start = Chess.initial;
  List<CommentMove> moves(String text) => parseProseComment(
    text,
    anchor: start,
  ).expand((p) => p).whereType<CommentMove>().toList();
  Position replay(List<CommentMove> tokens, CommentMove target) {
    final run = tokens.where((t) => t.runId == target.runId).toList();
    Position pos = Chess.fromSetup(Setup.parseFen(run.first.anchorFen!));
    for (final move in run) {
      pos = pos.play(pos.parseSan(move.san)!);
      if (identical(move, target)) break;
    }
    return pos;
  }

  test('single-spaced moves replay through prose and nested alternatives', () {
    final tokens = moves(
      '1. e4 c5 We choose 2.Nf3 d6 3.d4 cxd4 '
      '4.Nxd4 Nf6 5.Nc3 a6 (The Dragon is 5...g6 6.Be3 '
      '(6.f3 is another choice) Bg7 7.f3) 6.Bg5 e6 7.f4',
    );
    final target = tokens.last;
    expect(target.san, 'f4');
    Position expected = start;
    for (final san in [
      'e4',
      'c5',
      'Nf3',
      'd6',
      'd4',
      'cxd4',
      'Nxd4',
      'Nf6',
      'Nc3',
      'a6',
      'Bg5',
      'e6',
      'f4',
    ]) {
      expected = expected.play(expected.parseSan(san)!);
    }
    expect(replay(tokens, target).fen, expected.fen);
    expect(tokens.where((t) => t.san == 'Bg7'), hasLength(1));
  });

  test('rewinds numbered alternatives without contaminating other runs', () {
    final tokens = moves(
      '1.e4 c5 2.Nf3 Nc6 3.d4 cxd4 4.Nxd4 Nf6 '
      '5.Nc3 e5 6.Ndb5 d6 7.Bg5 a6 8.Na3 b5 9.Bxf6 gxf6 10.Nd5 '
      'Instead use 9.Nd5 Be7 10.Bxf6 Bxf6 11.c3',
    );
    expect(tokens.last.display, '11.c3');
    expect(replay(tokens, tokens.last).fullmoves, 11);
    expect(tokens.where((t) => t.display == '9.Nd5'), hasLength(1));
  });

  test('paragraph markers, bullets and known broken export counters', () {
    final paragraphs = parseProseComment(
      'Welcome [--] • 1... e4 1.e4 c5 '
      '2.Nf3 d6 3.d4 cxd4 4.Nxd4 Nf6 5.Nc3 a6 6.Bg5 e6 '
      '2... -- 7.f4 [--] • Next opening',
      anchor: start,
    );
    expect(paragraphs, hasLength(3));
    final text = paragraphs
        .expand((p) => p)
        .map((t) => t is CommentProse ? t.text : (t as CommentMove).display)
        .join();
    expect(text, isNot(contains('[--]')));
    expect(text, isNot(contains('1... e4')));
    expect(text, isNot(contains('2... --')));
    expect(
      paragraphs.expand((p) => p).whereType<CommentMove>().last.display,
      '7.f4',
    );
  });

  test('squares, impossible moves and missing plies stay prose', () {
    final tokens = moves(
      'Control e4 and f3. 1...e4 is wrong. '
      'We play 1.e4 c5 with a knight on f3. 7.a3 needs a position.',
    );
    expect(tokens.map((t) => t.san), ['e4', 'c5']);
  });

  test('handles Black-to-move FEN without assuming an initial board', () {
    final pos = Chess.fromSetup(
      Setup.parseFen('8/5k2/8/8/3K4/8/8/8 b - - 0 20'),
    );
    final tokens = parseProseComment(
      '20...Ke7 21.Kd5 Kd7 22.Kc5',
      anchor: pos,
    ).expand((p) => p).whereType<CommentMove>().toList();
    expect(tokens, hasLength(4));
    expect(replay(tokens, tokens.last).fen, '8/3k4/8/2K5/8/8/8/8 b - - 4 22');
  });
}
