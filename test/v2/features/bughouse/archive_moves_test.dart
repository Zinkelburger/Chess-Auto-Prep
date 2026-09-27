import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/features/bughouse/archive_moves.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedFicsBook book;
  late ArchiveMoves archive;

  setUp(() {
    lab = BughouseLab();
    book = ScriptedFicsBook();
    archive = ArchiveMoves(lab: lab, book: book);
  });

  tearDown(() {
    archive.dispose();
    lab.dispose();
  });

  test('a machine without the archive shows nothing', () async {
    await archive.open();
    expect(archive.available, isFalse);
    expect(archive.lookup, isNull);
  });

  test('present, it follows the table on the boards', () async {
    book.present = true;
    book.positions[TablePosition.initial.bookKey] = (
      games: 900,
      moves: [
        (
          board: BoardNumber.one,
          mover: Side.white,
          san: 'e4',
          games: 900,
          abWins: 450,
          cdWins: 400,
          draws: 20,
          unknown: 30,
          averageElo: 1800,
        ),
      ],
    );
    await archive.open();
    await pumpEventQueue();
    final start = archive.lookup as FicsFound;
    expect(start.position.moves.single.san, 'e4');
    lab.play(BoardNumber.one, 'e2e4');
    await pumpEventQueue();
    expect((archive.lookup as FicsFound).position.games, 0);
  });
}
