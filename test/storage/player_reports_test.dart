import 'dart:io';

import 'package:chess_auto_prep/storage/player_reports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = 'a' * 64, b = 'b' * 64, c = 'c' * 64;

  test('deleting a person\'s reports leaves everyone else\'s', () async {
    final folder = await Directory.systemTemp.createTemp('player-reports-');
    addTearDown(() => folder.delete(recursive: true));
    final reports = PlayerReports(folder);
    await reports.keep(a, {'version': 1, 'player': 'jane'});
    await reports.keep(b, {'version': 1, 'player': 'bob'});
    await reports.keep(c, {'version': 1});
    await reports.discardFor('jane');
    expect(await reports.read(a), isNull);
    expect(await reports.read(b), isNotNull);
    expect(await reports.read(c), isNotNull);
  });

  test('in memory too', () async {
    final reports = PlayerReports();
    await reports.keep(a, {'version': 1, 'player': 'jane'});
    await reports.discardFor('jane');
    expect(await reports.read(a), isNull);
  });
}
