import '../../../models/opening_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../chess_core/pgn/repertoire_headers.dart';

/// Everything one repertoire load produces, computed without touching
/// controller state so a superseded load can be discarded whole.
class LoadedRepertoire {
  const LoadedRepertoire({
    required this.pgn,
    required this.openingTree,
    required this.lines,
    required this.headers,
  });

  /// The PGN text this result was derived from, or null when there was none.
  final String? pgn;

  /// Null only for [missing] — a file that does not exist. An unparsable or
  /// empty PGN still yields an empty [OpeningTree].
  final OpeningTree? openingTree;

  final List<RepertoireLine> lines;

  /// Null when the PGN could not be read far enough to determine them; the
  /// caller then keeps its current headers.
  final RepertoireHeaders? headers;

  /// The result for a repertoire with no readable file behind it.
  static const missing = LoadedRepertoire(
    pgn: null,
    openingTree: null,
    lines: <RepertoireLine>[],
    headers: null,
  );
}
