/// Convert a PGN file into a Scid v5 database (`.si5` / `.sg5` / `.sn5`).
///
///     dart run tools/scid_export.dart games.pgn out_dir [name]
///
/// The same encoder the app's export uses, exposed as a CLI so a conversion
/// can be scripted, and so the output can be checked against Scid itself
/// without going through the UI.
library;

import 'dart:io' as io;

import 'package:chess_auto_prep/services/scid/scid_writer.dart';
import 'package:dartchess/dartchess.dart';

Future<int> main(List<String> args) async {
  if (args.length < 2) {
    io.stderr.writeln(
      'usage: dart run tools/scid_export.dart <input.pgn> <out_dir> [name]',
    );
    return 2;
  }
  final input = io.File(args[0]);
  final baseName = input.path.split(io.Platform.pathSeparator).last;
  if (!input.existsSync()) {
    io.stderr.writeln('no such file: ${args[0]}');
    return 1;
  }
  final outDir = args[1];
  final name = args.length > 2
      ? args[2]
      : baseName.replaceAll(RegExp(r'\.pgn$'), '');

  final games = PgnGame.parseMultiGamePgn(input.readAsStringSync());
  io.stderr.writeln('parsed ${games.length} game(s)');

  final result = await ScidWriter.write(
    directory: outDir,
    name: name,
    games: Stream.fromIterable(games),
    description: 'Exported from $baseName',
    total: games.length,
  );

  io.stdout.writeln('wrote ${result.games} game(s), ${result.bytes} bytes');
  for (final path in result.paths) {
    io.stdout.writeln('  $path');
  }
  if (result.truncated.isNotEmpty) {
    io.stderr.writeln('truncated ${result.truncated.length}:');
    for (final t in result.truncated.take(10)) {
      io.stderr.writeln('  $t');
    }
  }
  if (result.skipped.isNotEmpty) {
    io.stderr.writeln('skipped ${result.skipped.length}:');
    for (final s in result.skipped.take(10)) {
      io.stderr.writeln('  $s');
    }
  }
  return 0;
}
