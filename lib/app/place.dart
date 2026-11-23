import '../chess/pgn/game_tree.dart';
import '../storage/chapter_files.dart';
import '../workspace/document/document_history.dart';
import 'mode.dart';

/// Where the user was, for Back and Forward: the mode, and the document on
/// the board and where in it.
final class Place {
  const Place({
    required this.mode,
    this.source,
    this.game,
    this.cursor = const NodePath.root(),
    this.scratch = false,
    this.board,
  });

  final Mode mode;

  /// The document on the board, or null for none or the analysis board.
  final ChapterRef? source;
  final int? game;
  final NodePath cursor;

  /// Whether the analysis board was up.
  final bool scratch;

  /// Which analysis board was up, when [scratch]: each mode has its own.
  final KeptBoard? board;

  /// `My games`, `Repertoire builder · Najdorf`: what Back's tooltip names.
  String get label => switch (source) {
    final source? => '${mode.label} · ${source.name}',
    null => mode.label,
  };

  bool sameAs(Place other) =>
      other.mode == mode &&
      other.source == source &&
      other.game == game &&
      other.scratch == scratch &&
      identical(other.board, board);
}
