// A TWIC import in its own process, for the tests that kill it
// half-way (`master_games_process_test.dart`) or run it on a full disk
// (`master_games_disk_full_test.dart`). Pure Dart, so `dart run` can start it.
//
//   import <database> <issue> <games>   import one issue and print `imported`
//   full <folder>                    the disk-full sequence, one JSON line
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:path/path.dart' as p;

const _line =
    '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 '
    '7. Bb3 d6 8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 1-0';

/// An issue of [games] games, each with its own players.
Uint8List issueZip(int issue, int games) {
  final text = StringBuffer();
  for (var i = 0; i < games; i++) {
    text.writeln('[Event "Issue $issue"]');
    text.writeln('[Site "London ENG"]');
    text.writeln('[White "White $issue-$i"]');
    text.writeln('[Black "Black $i"]');
    text.writeln('[Result "1-0"]');
    text.writeln();
    text.writeln(_line);
    text.writeln();
  }
  final bytes = utf8.encode('$text');
  return Uint8List.fromList(
    ZipEncoder().encode(
      Archive()..addFile(ArchiveFile('twic$issue.pgn', bytes.length, bytes)),
    ),
  );
}

Future<void> main(List<String> args) async {
  switch (args) {
    case ['import', final database, final issue, final games]:
      final zip = issueZip(int.parse(issue), int.parse(games));
      stdout.writeln('ready');
      importTwicIssue(database, int.parse(issue), zip);
      stdout.writeln('imported');
    case ['full', final folder]:
      stdout.writeln(jsonEncode(await _full(Directory(folder))));
    default:
      stderr.writeln(
        'usage: import <database> <issue> <games> | full <folder>',
      );
      exitCode = 64;
  }
}

/// Imports a small issue, fills the disk, tries a large one, frees the
/// space and tries it again.
Future<Map<String, Object?>> _full(Directory folder) async {
  final database = p.join(folder.path, 'master_games.db');
  final report = <String, Object?>{
    'first': importTwicIssue(database, 1, issueZip(1, 20)).$1,
  };
  final big = issueZip(2, 3000);
  final filler = <File>[];
  final chunk = List<int>.filled(4096, 0x78);
  try {
    for (var i = 0; i < 100000; i++) {
      final file = File(p.join(folder.path, 'filler-$i'));
      filler.add(file);
      await file.writeAsBytes(chunk, flush: true);
    }
  } on FileSystemException {
    // Full.
  }
  report['filled'] = filler.length - 1;
  try {
    importTwicIssue(database, 2, big);
    report['full'] = 'imported';
  } on Object catch (error) {
    report['full'] = describeImportFailure(error);
    report['error'] = '$error';
  }
  for (final file in filler) {
    if (file.existsSync()) await file.delete();
  }
  // A database in write-ahead-log mode cannot be opened at all while the
  // disk is full (SQLite must create its shared-memory index first), so
  // what the failed issue left behind is read once there is room.
  report['afterwards'] = masterGamesIssues(database).issues.toList()..sort();
  report['retried'] = importTwicIssue(database, 2, big).$1;
  report['finally'] = masterGamesIssues(database).issues.toList()..sort();
  report['leftovers'] = [
    for (final entity in folder.listSync())
      if (p.basename(entity.path) != 'master_games.db') p.basename(entity.path),
  ];
  return report;
}
