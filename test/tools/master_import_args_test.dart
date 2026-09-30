import 'package:flutter_test/flutter_test.dart';

import '../../tools/master_import_pgn.dart' show importArguments;

void main() {
  test('paths on one line are separated by spaces', () {
    expect(importArguments(' out.db  a.pgn\tb.pgn '), [
      'out.db',
      'a.pgn',
      'b.pgn',
    ]);
    expect(importArguments('  '), isEmpty);
  });

  test('paths one per line may contain spaces', () {
    expect(
      importArguments('/home/me/My DB/out.db\n/home/me/My PGNs/a b.pgn\n'),
      ['/home/me/My DB/out.db', '/home/me/My PGNs/a b.pgn'],
    );
    expect(importArguments('out.db\r\n\r\nin.pgn'), ['out.db', 'in.pgn']);
  });
}
