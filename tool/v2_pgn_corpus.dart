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
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/rewrite_gate.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:dartchess/dartchess.dart' show NormalMove, Position;

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
  BranchTry branch,
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
  _printBranching(reports);
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
  // The same reading the store does, so the tool and the app agree on what
  // a file holds and on which files the app will not write back.
  final read = readDocumentText(bytes);
  final text = switch (read) {
    PlainText(:final text) => text,
    ForeignText(:final text) => text,
    NotText() => null,
  };
  if (text == null) {
    return (
      path: file.path,
      bytes: bytes.length,
      games: 0,
      whole: 0,
      rewritable: 0,
      sameBytes: false,
      milliseconds: 0,
      losses: ['${file.path}: ${(read as NotText).detail}'],
      branch: (tried: false, failure: null),
    );
  }
  final clock = Stopwatch()..start();
  final document = splitChapterText(text);
  final games = [for (final game in document.games) readGame(game.text)];
  clock.stop();
  final losses = <String>[];
  var rewritable = 0;
  for (final (index, game) in games.indexed) {
    final loss = _lossOf(game, document.games[index]);
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
  if (read is ForeignText) {
    losses.add('${file.path}: ${read.detail}, so it opens to read only');
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
    branch: read is PlainText
        ? tryBranchingBelowANullMove(file.path, text)
        : (tried: false, failure: null),
  );
}

/// Whether a file held a ply where nobody moved, and what playing a move
/// below it did.
typedef BranchTry = ({bool tried, String? failure});

/// Plays one move below the first ply where nobody moved in [text], to see
/// that the chapter comes back holding it. Nothing is written anywhere.
///
/// Replaying a line used to stop at `--`, which turned a branch below a
/// Chessable waiting move into a game with no moves in it at all.
BranchTry tryBranchingBelowANullMove(String path, String text) {
  final chapter = parseChapter(name: path, text: text);
  final at = _firstNullMove(chapter.tree);
  if (at == null) return (tried: false, failure: null);
  final from = positionOf(chapter.tree.fenAt(at));
  final move = from == null ? null : _aLegalMove(from);
  if (move == null) return (tried: false, failure: null);
  final result = addMove(chapter, at: at, uci: move);
  if (result is! MoveAdded) {
    return (tried: true, failure: '$path: $move below a null move was refused');
  }
  final played = result.chapter.tree.nodeAt(result.path);
  return (
    tried: true,
    failure: played == null
        ? '$path: the chapter came back without $move'
        : null,
  );
}

NodePath? _firstNullMove(GameTree tree) {
  var path = const NodePath.root();
  var siblings = tree.children;
  while (siblings.isNotEmpty) {
    final index = siblings.indexWhere((node) => node.san == nullMoveSan);
    if (index >= 0) return path.child(index);
    path = path.child(0);
    siblings = siblings.first.children;
  }
  return null;
}

String? _aLegalMove(Position from) {
  for (final entry in from.legalMoves.entries) {
    for (final to in entry.value.squares) {
      final move = NormalMove(from: entry.key, to: to);
      if (from.isLegal(move)) return move.uci;
    }
  }
  return null;
}

/// Why [game] could not be written again, or null when it can.
///
/// It asks the gate the app asks, rather than a second copy of the rule.
String? _lossOf(GameRead game, GameSpan span) {
  final tree = game.tree;
  if (tree == null) return game.issues.firstOrNull?.toString() ?? 'no position';
  final line = ChapterLine(
    tags: game.tags,
    tree: tree,
    text: span.text,
    trailer: span.trailer,
    terminator: game.terminator,
    separator: game.separator,
    issues: game.issues,
  );
  return switch (rewritten(line, tree)) {
    LineRewritten() => null,
    LineRefused() when game.issues.isNotEmpty => game.issues.first.toString(),
    LineRefused(:final reason) => reason,
  };
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

/// One move played below a null move in every file that has one, in memory.
void _printBranching(List<FileReport> reports) {
  var tried = 0;
  final trouble = <String>[];
  for (final report in reports) {
    if (report.branch.tried) tried++;
    if (report.branch.failure case final failure?) trouble.add(failure);
  }
  stdout.writeln(
    '\nbranching below a null move: $tried files have one, '
    '${trouble.length} went wrong',
  );
  for (final line in trouble.take(10)) {
    stdout.writeln('  $line');
  }
}

int? _intFlag(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return int.tryParse(arguments[index + 1]);
}
