// Reads every .pgn file under a folder and reports what the v2 reader makes
// of it. It opens files and never writes, moves or deletes anything, so it
// is safe to point at the real Documents folder.
//
//   dart run tool/v2_pgn_corpus.dart [folder] [--losses N]
//
// For each file: how many games it holds, how many the reader took whole,
// how many survive being written again, and whether cutting the file into
// games and putting it back gives the same bytes. A game that is not whole is
// named with its first issue, so a real loss can be told from a genuinely
// malformed file. The milliseconds are reading alone, not the rewrite check.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/rewrite_gate.dart';

/// What one file's games came to.
typedef FileReport = ({
  String path,
  int bytes,
  int games,
  int whole,
  int rewritable,
  bool sameBytes,
  int milliseconds,
  List<String> losses,
});

void main(List<String> arguments) {
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  final folder = Directory(
    positional.isEmpty
        ? '${Platform.environment['HOME']}/Documents'
        : positional.first,
  );
  if (!folder.existsSync()) {
    stdout.writeln('no such folder: ${folder.path}');
    exitCode = 2;
    return;
  }
  final shown = _intFlag(arguments, '--losses') ?? 10;
  final reports = [for (final file in _pgnFiles(folder)) _read(file)];
  _printTable(reports);
  _printLosses(reports, shown);
}

List<File> _pgnFiles(Directory folder) {
  final files = <File>[];
  for (final entry in folder.listSync(recursive: true, followLinks: false)) {
    // A folder can be named `Main.pgn`; one is.
    if (entry is File && entry.path.endsWith('.pgn')) files.add(entry);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

FileReport _read(File file) {
  final bytes = file.readAsBytesSync();
  final text = _decoded(bytes);
  if (text == null) {
    return (
      path: file.path,
      bytes: bytes.length,
      games: 0,
      whole: 0,
      rewritable: 0,
      sameBytes: false,
      milliseconds: 0,
      losses: ['the file is not UTF-8 text'],
    );
  }
  final clock = Stopwatch()..start();
  final document = splitChapterText(text);
  final games = [for (final game in document.games) readGame(game.text)];
  clock.stop();
  final losses = <String>[];
  var rewritable = 0;
  for (final (index, game) in games.indexed) {
    final loss = _lossOf(game);
    if (loss == null) {
      rewritable++;
      continue;
    }
    losses.add('${file.path} game $index: $loss');
  }
  final rebuilt = StringBuffer(document.preamble);
  for (final game in document.games) {
    rebuilt
      ..write(game.text)
      ..write(game.trailer);
  }
  return (
    path: file.path,
    bytes: bytes.length,
    games: games.length,
    whole: games.where((game) => game.rewritable).length,
    rewritable: rewritable,
    sameBytes: rebuilt.toString() == text,
    milliseconds: clock.elapsedMilliseconds,
    losses: losses,
  );
}

/// Why [game] could not be written again, or null when it can.
String? _lossOf(GameRead game) {
  final tree = game.tree;
  if (tree == null) return game.issues.firstOrNull?.toString() ?? 'no position';
  if (game.issues.isNotEmpty) return game.issues.first.toString();
  final rewrite = safeGameText(
    tags: game.tags,
    tree: tree,
    terminator: game.terminator,
    separator: game.separator,
  );
  return switch (rewrite) {
    RewriteReady() => null,
    RewriteRefused(:final reason) => reason,
  };
}

String? _decoded(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

void _printTable(List<FileReport> reports) {
  stdout.writeln(
    '${'games'.padLeft(7)} ${'whole'.padLeft(7)} ${'writable'.padLeft(9)} '
    '${'bytes'.padLeft(10)} ${'ms'.padLeft(6)}  same  file',
  );
  for (final report in reports) {
    stdout.writeln(
      '${report.games.toString().padLeft(7)} '
      '${report.whole.toString().padLeft(7)} '
      '${report.rewritable.toString().padLeft(9)} '
      '${report.bytes.toString().padLeft(10)} '
      '${report.milliseconds.toString().padLeft(6)}  '
      '${report.sameBytes ? ' yes' : ' NO '}  ${report.path}',
    );
  }
  stdout.writeln(_totals(reports));
}

String _totals(List<FileReport> reports) {
  var games = 0;
  var whole = 0;
  var rewritable = 0;
  var bytes = 0;
  var milliseconds = 0;
  var changed = 0;
  for (final report in reports) {
    games += report.games;
    whole += report.whole;
    rewritable += report.rewritable;
    bytes += report.bytes;
    milliseconds += report.milliseconds;
    if (!report.sameBytes) changed++;
  }
  return '\n${reports.length} files, $bytes bytes, $games games: '
      '$whole read whole, $rewritable survive a rewrite, '
      '$changed files do not come back byte for byte, ${milliseconds}ms';
}

void _printLosses(List<FileReport> reports, int shown) {
  final losses = [for (final report in reports) ...report.losses];
  if (losses.isEmpty) {
    stdout.writeln('nothing was lost.');
    return;
  }
  stdout.writeln('\n${losses.length} games keep their own bytes:');
  for (final loss in losses.take(shown)) {
    stdout.writeln('  $loss');
  }
}

int? _intFlag(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return int.tryParse(arguments[index + 1]);
}
