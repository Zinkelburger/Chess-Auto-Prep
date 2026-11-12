import 'dart:io';

import 'package:chess_auto_prep/storage/compound_commit.dart';
import 'package:chess_auto_prep/storage/line_progress.dart';
import 'package:chess_auto_prep/storage/operation_participants.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _from = '/home/u/Documents/repertoires/KID/Main.pgn';
const _to = '/home/u/Documents/repertoires/KID/Sidelines.pgn';

String _rows(String name, List<String> rows, {bool marked = false}) =>
    '${marked ? '\uFEFF' : ''}${[headerOf(name), ...rows].join('\n')}\n';

void main() {
  test('a move is read back from files that start with a byte-order mark', () {
    expect(
      lineMovesBetween([
        CompoundTraining(
          name: streaksFile,
          before: _rows(streaksFile, ['$_from,a,0,1,true'], marked: true),
          after: _rows(streaksFile, ['$_to,a,0,1,true'], marked: true),
        ),
      ]),
      {(source: _from, id: 'a'): (source: _to, id: 'a')},
    );
  });

  test('a file the move left alone does not make it look followed', () async {
    final documents = await Directory.systemTemp.createTemp('line-rows-');
    addTearDown(() => documents.delete(recursive: true));
    final reviews = _rows(reviewsFile, const []);
    final rows = LineRows(documents, [
      CompoundTraining(
        name: streaksFile,
        before: _rows(streaksFile, ['$_from,a,0,1,true']),
        after: _rows(streaksFile, ['$_to,a,0,1,true']),
      ),
      CompoundTraining(name: reviewsFile, before: reviews, after: reviews),
    ]);
    // Another program rewrote the streaks; the reviews are as they were.
    File(
      p.join(documents.path, streaksFile),
    ).writeAsStringSync(_rows(streaksFile, ['$_from,a,0,3,true']));
    File(p.join(documents.path, reviewsFile)).writeAsStringSync(reviews);
    expect(await rows.look(), isA<HoldsOther>());
  });
}
