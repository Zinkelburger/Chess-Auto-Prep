/// Pure PGN-authoring logic extracted from [RepertoireController].
///
/// This unit knows how to build PGN game text and [RepertoireLine] objects
/// from move lists. It holds no mutable session state — the controller keeps
/// ownership of state and notification; this class is a stateless collaborator
/// so the authoring logic can be unit-tested in isolation.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';
import 'package:collection/collection.dart';

import '../../../models/repertoire_line.dart';
import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../chess_core/pgn/repertoire_line_ids.dart';
import '../../../chess_core/pgn/repertoire_pgn_text.dart';
import '../../../chess_core/pgn/pgn_position_replay.dart';
import '../../../utils/movetext_builder.dart';

class RepertoireAuthoring {
  const RepertoireAuthoring();

  Position _startPosition(String pgn) {
    try {
      return startPositionFromGame(parsePgnGame(pgn));
    } catch (_) {
      return Chess.initial;
    }
  }

  /// Build a complete PGN game (headers + movetext) from [moveLines].
  /// Returns null when there are no moves.
  String? buildGame({
    String? event,
    String? date,
    String? white,
    String? black,
    String? result,
    required List<String> moveLines,
  }) {
    if (moveLines.isEmpty) return null;

    final headers = <String>[
      '[Event "${event ?? "Training Line"}"]',
      '[Date "${date ?? DateTime.now().toIso8601String().split('T')[0]}"]',
      '[White "${white ?? "Training"}"]',
      '[Black "${black ?? "Me"}"]',
      '[Result "${result ?? "1-0"}"]',
    ];

    return [...headers, '', moveLines.join(' ')].join('\n');
  }

  /// A short default title for a line, e.g. "Line: e4 e5 Nf3".
  String defaultLineTitle(List<String> moves) {
    if (moves.length >= 3) {
      return 'Line: ${moves.take(3).join(' ')}';
    }
    return 'Repertoire Line';
  }

  /// The last game in a multi-game PGN (or the whole string if only one).
  ///
  /// Cut from the last `[Event ` line start, the same boundary
  /// [pgn.splitPgnIntoGames] uses, so a browse add does not re-split the
  /// whole updated file to take one game off its end.  Text with no `[Event `
  /// header (a bare move list) still goes through the splitter, which
  /// synthesises headers for it.
  String extractLastGamePgn(String fullPgn) {
    final start = pgn.lastGameStart(fullPgn);
    if (start < 0) {
      final games = pgn.splitPgnIntoGames(fullPgn);
      return games.isEmpty ? fullPgn : games.last;
    }
    // The splitter terminates its last chunk with one extra newline.
    return '${fullPgn.substring(start)}\n';
  }

  /// Index of the line whose moves exactly equal [prefix], or null.
  int? findLineIndexForPrefix(List<RepertoireLine> lines, List<String> prefix) {
    for (int i = 0; i < lines.length; i++) {
      if (const ListEquality<String>().equals(lines[i].moves, prefix)) return i;
    }
    return null;
  }

  /// [moves] as numbered movetext from [startingFen], so a black-to-move or
  /// mid-game root gets `N...` numbering rather than starting at `1.`.  An
  /// unparsable FEN falls back to standard-start numbering.
  String numberedMovetext(List<String> moves, {required String startingFen}) {
    if (moves.isEmpty) return '';
    var startMoveNumber = 1;
    var whiteToMoveFirst = true;
    try {
      final setup = Setup.parseFen(startingFen);
      startMoveNumber = setup.fullmoves;
      whiteToMoveFirst = setup.turn == Side.white;
    } on FenException {
      // Standard-start numbering.
    }
    return buildNumberedMovetext(
      moves,
      startMoveNumber: startMoveNumber,
      whiteToMoveFirst: whiteToMoveFirst,
    );
  }

  /// Construct a brand-new [RepertoireLine] for [moves].
  ///
  /// [index] is the position in the current lines list (used for id + default
  /// naming); [isWhite] selects the repertoire color.
  RepertoireLine buildNewLine({
    required List<String> moves,
    required String title,
    required String pgnContent,
    required int index,
    required bool isWhite,
    Iterable<String> existingIds = const [],
  }) {
    final id = repertoireLineIds.forNewLine(
      moves,
      index,
      existingIds: existingIds,
    );
    final name = title.isNotEmpty && title != 'Repertoire Line'
        ? title
        : (moves.length >= 3
              ? 'Line: ${moves.take(3).join(' ')}'
              : 'Repertoire Line ${index + 1}');
    final Position startPosition = _startPosition(pgnContent);

    return RepertoireLine(
      id: id,
      name: name,
      moves: moves,
      color: isWhite ? 'white' : 'black',
      startPosition: startPosition,
      fullPgn: pgnContent,
    );
  }

  /// Return a copy of [line] extended by [newMove], with PGN updated.
  RepertoireLine extendLine(RepertoireLine line, String newMove) {
    return RepertoireLine(
      id: line.id,
      name: line.name,
      moves: [...line.moves, newMove],
      color: line.color,
      startPosition: line.startPosition,
      fullPgn: appendSanToGamePgn(line.fullPgn, line.moves, newMove),
      comments: line.comments,
      headers: line.headers,
      importance: line.importance,
    );
  }
}
