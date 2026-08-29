/// Repertoire training line model
/// Represents a single trainable line extracted from PGN mainline
library;

import 'package:dartchess/dartchess.dart';

import '../utils/pgn_comment_utils.dart' show filterDisplayComment;
import '../utils/training_markers.dart' show hasPuzzleStart, hasPuzzleEnd;

/// Tag holding a model game's real White player.  A model game has to carry
/// `[Result "*"]` and a chapter title in `[White]` for header-based chapter
/// detection to work, so its real identity moves to `ModelGame*` tags — and
/// their presence is what marks the game as illustration rather than book.
const String kModelGameWhiteTag = 'ModelGameWhite';
const String kModelGameBlackTag = 'ModelGameBlack';
const String kModelGameResultTag = 'ModelGameResult';
const String kModelGameEventTag = 'ModelGameEvent';
const String kModelGameDateTag = 'ModelGameDate';
const String kModelGameWhiteEloTag = 'ModelGameWhiteElo';
const String kModelGameBlackEloTag = 'ModelGameBlackElo';

/// Whether [headers] belong to a model game rather than a repertoire line.
bool isModelGameHeaders(Map<String, String> headers) =>
    headers.containsKey(kModelGameWhiteTag) ||
    headers.containsKey(kModelGameResultTag);

class RepertoireLine {
  final String id;
  final String name; // e.g., "French Defense - Main Line"
  final List<String> moves; // SAN moves: ["e4", "e6", "d4", "d5", ...]
  final String color; // "white" or "black" - which side we're training
  final Position startPosition; // Usually Chess.initial
  final String fullPgn; // Original PGN for reference
  final Map<String, String> comments; // Move comments keyed by move index
  /// Raw PGN headers — includes review metadata like LastReview, Difficulty, etc.
  final Map<String, String> headers;

  /// Cumulative path probability from PGN ([CumProb] header or comment).
  final double? importance;

  /// Chapter this line belongs to, when the source file carries chapter
  /// metadata (Chessable exports title every game with the chapter in the
  /// [White] header). Null for files without chapters.
  final String? chapter;

  /// A real game included as illustration, not a line you are meant to know
  /// (see the generator's "Model games" chapter). It is somebody else's moves
  /// in a file full of yours, so it must never be drilled, and must never
  /// count as your book when your own games are checked against the file.
  final bool isModelGame;

  /// Position of this game in its PGN file (0-based, counting every game,
  /// including ones that failed to parse), or -1 when unknown. [id] is not
  /// guaranteed unique — the move-based fallback truncates, so lines sharing
  /// a long opening prefix collide — so file edits that must hit exactly this
  /// game address it by index.
  final int gameIndex;

  RepertoireLine({
    required this.id,
    required this.name,
    required this.moves,
    required this.color,
    required this.startPosition,
    required this.fullPgn,
    this.comments = const {},
    this.headers = const {},
    this.importance,
    this.chapter,
    this.isModelGame = false,
    this.gameIndex = -1,
  });

  /// The same line under a different id (collision resolution at parse time).
  RepertoireLine copyWithId(String newId) => _copyWith(id: newId);

  /// The same line trained from the other side. Used when a file declares no
  /// colour and the parser reads it off the move tree instead.
  RepertoireLine copyWithColor(String newColor) => _copyWith(color: newColor);

  RepertoireLine _copyWith({String? id, String? color}) => RepertoireLine(
    id: id ?? this.id,
    name: name,
    moves: moves,
    color: color ?? this.color,
    startPosition: startPosition,
    fullPgn: fullPgn,
    comments: comments,
    headers: headers,
    importance: importance,
    chapter: chapter,
    isModelGame: isModelGame,
    gameIndex: gameIndex,
  );

  /// Gets the total number of trainable moves in this line
  int get totalMoves => moves.length;

  /// "6) Tartakower 8.Rc1 › 8.Rc1 Bb7 #3" — the name plus the chapter it sits
  /// in, for the places that show one line with no chapter around it (the
  /// Train tab, the preview dialog, a results summary). Inside a chapter's own
  /// list the chapter is already the heading, so [name] is used there instead.
  ///
  /// Course exports often repeat the chapter inside the variation title; when
  /// they do, saying it twice is noise, so the prefix is dropped.
  String get qualifiedName {
    final chapter = this.chapter?.trim();
    if (chapter == null || chapter.isEmpty) return name;
    final lower = name.toLowerCase();
    final chapterLower = chapter.toLowerCase();
    if (lower == chapterLower || lower.startsWith(chapterLower)) return name;
    return '$chapter › $name';
  }

  int? _uncommentedIntroLength;

  /// Number of leading moves before the first human-annotated move — the
  /// "book intro" that [TrainingSettings.skipToFirstComment] auto-plays
  /// instead of quizzing. Engine-token comments (`[%eval]`, `[%cumProb]`, …)
  /// don't count as annotations. Returns 0 when the line has no prose
  /// comments at all (nothing to anchor the tabiya, so the whole line trains
  /// normally).
  int get uncommentedIntroLength {
    return _uncommentedIntroLength ??= () {
      for (int i = 0; i < moves.length; i++) {
        final raw = comments[i.toString()];
        if (raw != null && filterDisplayComment(raw).isNotEmpty) {
          return i;
        }
      }
      return 0; // no prose comments anywhere
    }();
  }

  bool _puzzleMarkersComputed = false;
  int? _puzzleStartIndex;
  int? _puzzleEndIndex;

  void _computePuzzleMarkers() {
    if (_puzzleMarkersComputed) return;
    _puzzleMarkersComputed = true;
    for (int i = 0; i < moves.length; i++) {
      final comment = comments[i.toString()];
      if (_puzzleStartIndex == null && hasPuzzleStart(comment)) {
        _puzzleStartIndex = i;
      }
      if (_puzzleEndIndex == null && hasPuzzleEnd(comment)) {
        _puzzleEndIndex = i;
      }
    }
  }

  /// Index of the move carrying the `[%tstart]` puzzle marker — the first
  /// move the trainer quizzes (earlier moves auto-play as intro). Null when
  /// the line has no marker and trains from the top as before.
  int? get puzzleStartIndex {
    _computePuzzleMarkers();
    return _puzzleStartIndex;
  }

  /// Index of the move carrying the `[%tend]` puzzle marker — the last move
  /// the trainer quizzes. Null trains to the end of the line.
  int? get puzzleEndIndex {
    _computePuzzleMarkers();
    return _puzzleEndIndex;
  }

  /// Checks if this line trains the specified color
  bool trainsColor(String colorToTrain) => color == colorToTrain;

  @override
  String toString() => 'RepertoireLine($name: ${moves.join(" ")})';
}

/// "1.e4 e6 2.d4 d5" movetext for [line] from ply [start] (inclusive) to
/// [end] (exclusive; defaults to the whole line).
String formatLineMovesText(RepertoireLine line, {int start = 0, int? end}) {
  final stop = (end ?? line.moves.length).clamp(0, line.moves.length);
  final startFullmoves = line.startPosition.fullmoves;
  final startIsWhite = line.startPosition.turn == Side.white;
  final parts = <String>[];
  for (int i = start; i < stop; i++) {
    final isWhite = startIsWhite ? i.isEven : i.isOdd;
    final number = startIsWhite
        ? startFullmoves + i ~/ 2
        : startFullmoves + (i + 1) ~/ 2;
    if (isWhite) {
      parts.add('$number.${line.moves[i]}');
    } else if (parts.isEmpty) {
      parts.add('$number...${line.moves[i]}');
    } else {
      parts.add(line.moves[i]);
    }
  }
  return parts.join(' ');
}
