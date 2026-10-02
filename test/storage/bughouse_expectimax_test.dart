import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess/bughouse/expectimax.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/storage/bughouse_expectimax.dart';

void main() {
  test(
    'evaluation checkpoints and both colour snapshots survive reopening',
    () async {
      final temp = await Directory.systemTemp.createTemp('bughouse-book-test-');
      final path = '${temp.path}/book.db';
      var book = BughouseExpectimaxBook(path);
      var calls = 0;
      Future<BughouseEvaluation> run(TablePosition p, BoardNumber b) async {
        calls++;
        return (value: .2, best: 'e2e4', nodes: 1500, depth: 9);
      }

      final root = TablePosition.initial;
      await book.evaluate(root, BoardNumber.one, 1500, 'engine1', run);
      book.close();
      book = BughouseExpectimaxBook(path);
      final known = await book.evaluate(
        root,
        BoardNumber.one,
        1500,
        'engine1',
        run,
      );
      expect(calls, 1);
      expect(known.depth, 9);
      final reused = await book.evaluate(
        root,
        BoardNumber.one,
        800,
        'engine1',
        run,
      );
      expect(reused.nodes, 1500);
      expect(calls, 1);
      await book.evaluate(root, BoardNumber.one, 1500, 'engine2', run);
      expect(calls, 2);
      final played = root.play(BoardNumber.one, 'e2e4')!;
      final rows = [
        BughouseBranch(
          played.move,
          .3,
          BughouseNode(
            position: played.after,
            evaluation: .1,
            white: .3,
            black: -.1,
            nodes: 1500,
            depth: 8,
            coverage: .7,
          ),
        ),
      ];
      const options = BughouseSearchOptions();
      await book.save(root, BoardNumber.one, options, rows);
      book.close();
      book = BughouseExpectimaxBook(path);
      final found = await book.load(root, BoardNumber.one, options);
      expect(found!.single.child.white, .3);
      expect(found.single.child.black, -.1);
      expect(found.single.child.position.keyText, played.after.keyText);
      expect(await book.load(played.after, BoardNumber.one, options), isNull);
      expect(await book.load(root, BoardNumber.two, options), isNull);
      book.close();
      await temp.delete(recursive: true);
    },
  );
}
