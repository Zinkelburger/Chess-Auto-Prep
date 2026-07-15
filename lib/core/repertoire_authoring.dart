/// Pure PGN-authoring logic extracted from [RepertoireController].
///
/// This unit knows how to build PGN game text and [RepertoireLine] objects
/// from move lists. It holds no mutable session state — the controller keeps
/// ownership of state and notification; this class is a stateless collaborator
/// so the authoring logic can be unit-tested in isolation.
///
/// See `docs/REFACTOR_PLAN.md` Phase 3.
library;

import 'package:dartchess/dartchess.dart';

import '../models/repertoire_line.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/repertoire_service.dart';

class RepertoireAuthoring {
  final RepertoireService _service;

  RepertoireAuthoring([RepertoireService? service])
    : _service = service ?? RepertoireService();

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
  String extractLastGamePgn(String fullPgn) {
    final games = pgn.splitPgnIntoGames(fullPgn);
    return games.isEmpty ? fullPgn : games.last;
  }

  /// Index of the line whose moves exactly equal [prefix], or null.
  int? findLineIndexForPrefix(List<RepertoireLine> lines, List<String> prefix) {
    for (int i = 0; i < lines.length; i++) {
      final moves = lines[i].moves;
      if (moves.length == prefix.length && _listEquals(moves, prefix)) {
        return i;
      }
    }
    return null;
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
  }) {
    final id = _service.generateLineId(moves, index);
    final name = title.isNotEmpty && title != 'Repertoire Line'
        ? title
        : (moves.length >= 3
              ? 'Line: ${moves.take(3).join(' ')}'
              : 'Repertoire Line ${index + 1}');
    final Position startPosition = _service.extractStartPositionFromPgn(
      pgnContent,
    );

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
      fullPgn: _service.appendSanToGamePgn(line.fullPgn, line.moves, newMove),
      comments: line.comments,
      variations: line.variations,
      headers: line.headers,
      importance: line.importance,
    );
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
