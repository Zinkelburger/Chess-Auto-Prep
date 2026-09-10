import 'package:chess_auto_prep/core/pgn/pgn_copy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps headers and result, removes all annotations and nested sidelines',
    () {
      const pgn = '''
[White "Alice"]
[Black "Bob"]
[Result "1-0"]

{Intro} 1. e4! {[%eval 0.3] Main note} (1. d4 d5 (1... Nf6))
e5 \$2 ; end-of-line comment
2. Nf3 {[%cal Gg1f3]} Nc6 1-0
''';
      expect(mainlinePgnWithoutComments(pgn), '''
[White "Alice"]
[Black "Bob"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0''');
    },
  );

  test('preserves a custom position with Black to move and move numbering', () {
    const headers = '''
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 17"]''';
    expect(
      mainlinePgnWithoutComments('$headers\n\n17... e5 {note} 18. e4 *'),
      '$headers\n\n17... e5 18. e4 *',
    );
  });

  test('handles headerless games and games without moves', () {
    expect(mainlinePgnWithoutComments('1. e4!? e5 *'), '1. e4 e5 *');
    expect(mainlinePgnWithoutComments('{Intro} *'), '*');
  });
}
