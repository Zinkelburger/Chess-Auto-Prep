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

  test('a report from another version reads as none', () async {
    final folder = await Directory.systemTemp.createTemp('player-reports-');
    addTearDown(() => folder.delete(recursive: true));
    final reports = PlayerReports(folder);
    await reports.keep(a, {'version': 2, 'player': 'jane'});
    expect(await reports.read(a), isNull);
  });

  test('the first report makes its whole folder', () async {
    final root = await Directory.systemTemp.createTemp('player-reports-');
    addTearDown(() => root.delete(recursive: true));
    final reports = PlayerReports(Directory('${root.path}/cache/reports'));
    await reports.keep(a, {'version': 1});
    expect(await reports.read(a), {'version': 1});
  });

  test('deleting a person\'s reports touches only report files', () async {
    final folder = await Directory.systemTemp.createTemp('player-reports-');
    addTearDown(() => folder.delete(recursive: true));
    final notes = File('${folder.path}/notes.txt')
      ..writeAsStringSync('{"player": "jane"}');
    await PlayerReports(folder).discardFor('jane');
    expect(notes.existsSync(), isTrue);
  });

  test('in memory too', () async {
    final reports = PlayerReports();
    await reports.keep(a, {'version': 1, 'player': 'jane'});
    await reports.discardFor('jane');
    expect(await reports.read(a), isNull);
  });
}
