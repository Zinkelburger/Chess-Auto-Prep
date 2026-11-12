import 'package:chess_auto_prep/chess/openings.dart';
import 'package:chess_auto_prep/workspace/explorer/opening_names.dart';
import 'package:flutter_test/flutter_test.dart';

const _volume =
    'eco\tname\tpgn\n'
    'C20\tKing\'s Pawn Game\t1. e4 e5\n'
    'C60\tRuy Lopez\t1. e4 e5 2. Nf3 Nc6 3. Bb5\n';

void main() {
  test('the names arrive once, and listeners hear it', () async {
    final names = OpeningNames(() async => [_volume]);
    addTearDown(names.dispose);
    var heard = 0;
    names.addListener(() => heard++);
    expect(names.book, same(Openings.none));
    final book = await names.load();
    expect(book, isNot(same(Openings.none)));
    expect(names.book, same(book));
    expect(heard, 1);
  });

  test('names read after their owner went are still the answer', () async {
    final names = OpeningNames(() async => [_volume]);
    final loading = names.load();
    names.dispose();
    expect(await loading, isNot(same(Openings.none)));
  });
}
