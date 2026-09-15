/// Serializes a played game the way engine-testing tools and the app's own
/// PGN Viewer both expect it.
///
/// Move comments are opt-in (`GamePgnContext.annotateMoves`). When they are
/// on, the scores follow the cutechess convention — the value the engine
/// reported, from *its own* side's point of view — so `{+0.31/24 2.0s}` after
/// a Black move means Black thinks Black is better.
library;

import 'package:dartchess/dartchess.dart';

import '../../../constants/chess_constants.dart';
import '../../../models/game_outcome.dart';
import '../../../services/generation/export/pgn_game_writer.dart'
    show escapePgnHeaderValue;
import '../../../utils/movetext_builder.dart';
import '../models/time_control.dart';
import 'uci_protocol.dart';

/// Header material that comes from the tournament rather than the game.
class GamePgnContext {
  const GamePgnContext({
    required this.event,
    required this.site,
    required this.round,
    required this.startFen,
    required this.timeControl,
    this.openingLabel = '',
    this.annotateMoves = false,
  });

  final String event;
  final String site;
  final int round;
  final String startFen;
  final TimeControl timeControl;
  final String openingLabel;

  /// Write the engine's score/depth/time after every move.
  ///
  /// Off by default: a comment on every ply is what engine-testing tools want
  /// and what makes the game unreadable for anyone opening it in the PGN
  /// viewer, which is where these games are usually opened.
  final bool annotateMoves;
}

/// Serialize a finished game. Public so the headless runner and the tests can
/// build the same text the app writes.
///
/// [comments] holds one [formatMoveComment] per entry of [sanMoves]; it is
/// only written when [GamePgnContext.annotateMoves] is on.
String buildGamePgn({
  required String whiteName,
  required String blackName,
  required GamePgnContext context,
  required Position? startPosition,
  required List<String> sanMoves,
  required List<String> comments,
  required GameResult result,
  required TerminationReason termination,
  required String detail,
  required DateTime began,
  required Duration duration,
}) {
  final headers = <String, String>{
    'Event': context.event,
    'Site': context.site,
    'Date': _pgnDate(began),
    'Round': '${context.round}',
    'White': whiteName,
    'Black': blackName,
    'Result': result.pgnToken,
    if (context.openingLabel.isNotEmpty) 'Opening': context.openingLabel,
    'TimeControl': context.timeControl.pgnTag,
    'Termination': termination.pgnTag,
    'PlyCount': '${sanMoves.length}',
    'WhiteType': 'program',
    'BlackType': 'program',
    'GameStartTime': began.toIso8601String(),
    'GameDuration': _hms(duration),
  };

  final buffer = StringBuffer();
  for (final entry in headers.entries) {
    if (entry.value.isEmpty) continue;
    buffer.writeln('[${entry.key} "${escapePgnHeaderValue(entry.value)}"]');
  }
  final needsFen =
      startPosition != null && context.startFen != kStandardStartFen;
  if (needsFen) {
    buffer
      ..writeln('[FEN "${context.startFen}"]')
      ..writeln('[SetUp "1"]');
  }
  buffer.writeln();

  // Why the game stopped is the first thing anyone opening the PGN wants,
  // and PGN's own Termination vocabulary is too coarse to carry it.
  final reason = detail.isEmpty
      ? termination.label
      : '${termination.label}: $detail';
  buffer.write('{${_commentSafe(reason)}} ');

  final movetext = buildNumberedMovetext(
    sanMoves,
    startMoveNumber: startPosition?.fullmoves ?? 1,
    whiteToMoveFirst: (startPosition?.turn ?? Side.white) == Side.white,
    suffix: !context.annotateMoves
        ? null
        : (index) => index < comments.length ? ' {${comments[index]}}' : null,
  );
  if (movetext.isNotEmpty) buffer.write('$movetext ');
  buffer.writeln(result.pgnToken);
  return buffer.toString();
}

/// `+0.31/24 2.001s` — cutechess's move comment, which every engine-testing
/// tool and most GUIs already know how to read. A search with no score at
/// all reads as `book`.
String formatMoveComment(EngineSearch search) {
  final buffer = StringBuffer();
  final mate = search.scoreMate;
  final cp = search.scoreCp;
  if (mate != null) {
    buffer.write('${mate >= 0 ? '+' : '-'}M${mate.abs()}');
  } else if (cp != null) {
    final pawns = cp / 100;
    buffer.write('${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(2)}');
  } else {
    buffer.write('book');
  }
  if (search.depth > 0) buffer.write('/${search.depth}');
  buffer.write(' ${(search.elapsedMs / 1000).toStringAsFixed(3)}s');
  return buffer.toString();
}

/// Braces close a PGN comment and newlines end a line of movetext, so
/// neither can survive inside one. Engine failure details carry raw stderr,
/// which is exactly where both turn up.
String _commentSafe(String text) =>
    text.replaceAll(RegExp(r'[{}]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

String _pgnDate(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}.'
    '${when.month.toString().padLeft(2, '0')}.'
    '${when.day.toString().padLeft(2, '0')}';

String _hms(Duration d) =>
    '${d.inHours.toString().padLeft(2, '0')}:'
    '${(d.inMinutes % 60).toString().padLeft(2, '0')}:'
    '${(d.inSeconds % 60).toString().padLeft(2, '0')}';
