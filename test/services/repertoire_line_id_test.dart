import 'dart:io';

import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Line ids must be unique within a file, and a file edit by id must land on
/// the line the app showed under that id — even when lines share a long
/// opening prefix, which is exactly when the truncated legacy id collides.
String _game(String event, String moves) =>
    '[Event "$event"]\n[Result "*"]\n\n$moves *\n';

const _prefix = '1. e4 e6 2. d4 d5 3. e5 c5 4. c3 Nc6 5. Nf3';

void main() {
  final service = RepertoireService();
  final pgn =
      '${_game('A', '$_prefix Qb6')}\n'
      '${_game('B', '$_prefix Bd7')}\n'
      '${_game('C', '$_prefix Nh6')}\n';

  test('lines sharing a long prefix get distinct ids', () {
    final lines = service.parseRepertoirePgn(pgn, trainingColor: 'black');
    final ids = lines.map((l) => l.id).toList();
    expect(ids.toSet().length, 3, reason: 'ids: $ids');
    // The first claimant keeps the legacy (truncated) id, so progress saved
    // under it survives; later collisions are re-derived.
    expect(ids[0], service.generateLineId(lines[0].moves, 0));
    expect(ids[1], isNot(service.generateLineId(lines[1].moves, 1)));
    expect(lines.map((l) => l.gameIndex), [0, 1, 2]);
  });

  test('ids are stable across parses', () {
    final a = service.parseRepertoirePgn(pgn, trainingColor: 'black');
    final b = service.parseRepertoirePgn(pgn, trainingColor: 'black');
    expect(a.map((l) => l.id), b.map((l) => l.id));
  });

  test('deleting by id removes that line, not its prefix twin', () async {
    final tmp = Directory.systemTemp.createTempSync('line_id_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/ch.pgn')..writeAsStringSync(pgn);

    final lines = service.parseRepertoirePgn(pgn, trainingColor: 'black');
    final target = lines[1]; // "B" — would have collided with "A"
    expect(await service.deleteLine(file.path, target.id), isTrue);

    final after = service.parseRepertoirePgn(
      file.readAsStringSync(),
      trainingColor: 'black',
    );
    expect(after.map((l) => l.name), ['A', 'C']);
  });

  test('renaming by id renames that line', () async {
    final tmp = Directory.systemTemp.createTempSync('line_id_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/ch.pgn')..writeAsStringSync(pgn);
    final lines = service.parseRepertoirePgn(pgn, trainingColor: 'black');
    expect(
      await service.updateLineTitle(file.path, lines[2].id, 'Nh6!'),
      isTrue,
    );
    final after = service.parseRepertoirePgn(
      file.readAsStringSync(),
      trainingColor: 'black',
    );
    expect(after.map((l) => l.name), ['A', 'B', 'Nh6!']);
  });

  test('a new in-memory line predicts the id a reload will give it', () {
    final lines = service.parseRepertoirePgn(pgn, trainingColor: 'black');
    final moves = [...lines[0].moves.sublist(0, 9), 'a5'];
    final predicted = service.newLineId(
      moves,
      3,
      existingIds: lines.map((l) => l.id),
    );
    final reparsed = service.parseRepertoirePgn(
      '$pgn\n${_game('D', '$_prefix a5')}\n',
      trainingColor: 'black',
    );
    expect(reparsed[3].id, predicted);
    expect(reparsed.map((l) => l.id).toSet().length, 4);
  });
}
