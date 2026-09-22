import 'dart:convert';

import '../chess/explorer_choice.dart';
import '../chess/tactics/puzzle_queue.dart';

/// What the user has chosen about the app as a whole: the few things two
/// reasonable people want different values for and the app cannot tell.
///
/// Everything else is a decision made in code, a thing a mode remembers
/// for itself, or configuration that travels with a job. A row is added
/// here only when something reads it.
final class Settings {
  const Settings({
    this.boardCoordinates = true,
    this.engineCores = 1,
    this.engineMemoryMb = 128,
    this.engineLines = 3,
    this.copyFilesIntoDocuments = true,
    this.opponentElo = 2200,
    this.coverOnceIn = 50,
    this.explorer = ExplorerChoice.defaults,
    this.puzzles = PuzzleFilter.defaults,
    this.autoAdvance = true,
  });

  /// Rank and file letters on the board.
  final bool boardCoordinates;

  /// Threads the workspace engine may use.
  final int engineCores;

  /// The engine's hash table, in megabytes.
  final int engineMemoryMb;

  /// How many lines the engine pane shows.
  final int engineLines;

  /// Whether a file opened from outside Documents is copied into
  /// `pgn_collections` first, so it can be edited and kept.
  final bool copyFilesIntoDocuments;

  /// The rating the opponent's replies are predicted for, everywhere a
  /// repertoire is measured: the Replies table, the gaps, the coverage.
  final int opponentElo;

  /// A reply counts as one to prepare for when the opponent plays it at
  /// least once in this many games at [opponentElo]. Fifty is Chessbook's
  /// default and about four opponent moves deep in a main line.
  final int coverOnceIn;

  /// Which database the Explorer tab asks and how it is narrowed. Not a
  /// row of the settings page: the tab's own gear is where it is chosen,
  /// and this is only where the choice is kept between launches.
  final ExplorerChoice explorer;

  /// Which puzzles Tactics plays and in what order. Chosen on the Tactics
  /// list, beside the count it changes; kept here between launches.
  final PuzzleFilter puzzles;

  /// Whether a solved puzzle gives way to the next one by itself.
  final bool autoAdvance;

  static const defaults = Settings();

  /// The most the engine rows accept: a table bigger than this or more
  /// lines than this is a tuning job, not a setting.
  static const maxMemoryMb = 4096;
  static const maxLines = 8;

  /// The ratings the model was trained on.
  static const minElo = 1100;
  static const maxElo = 2900;

  /// Fewer games than this and everything is a gap; more and nothing is.
  static const minCoverOnceIn = 5;
  static const maxCoverOnceIn = 1000;

  Settings copyWith({
    bool? boardCoordinates,
    int? engineCores,
    int? engineMemoryMb,
    int? engineLines,
    bool? copyFilesIntoDocuments,
    int? opponentElo,
    int? coverOnceIn,
    ExplorerChoice? explorer,
    PuzzleFilter? puzzles,
    bool? autoAdvance,
  }) => Settings(
    boardCoordinates: boardCoordinates ?? this.boardCoordinates,
    engineCores: engineCores ?? this.engineCores,
    engineMemoryMb: engineMemoryMb ?? this.engineMemoryMb,
    engineLines: engineLines ?? this.engineLines,
    copyFilesIntoDocuments:
        copyFilesIntoDocuments ?? this.copyFilesIntoDocuments,
    opponentElo: opponentElo ?? this.opponentElo,
    coverOnceIn: coverOnceIn ?? this.coverOnceIn,
    explorer: explorer ?? this.explorer,
    puzzles: puzzles ?? this.puzzles,
    autoAdvance: autoAdvance ?? this.autoAdvance,
  );

  /// The file's text. One flat object with plain names, so a person can
  /// read it and the old app's keys never collide with it.
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'boardCoordinates': boardCoordinates,
    'engineCores': engineCores,
    'engineMemoryMb': engineMemoryMb,
    'engineLines': engineLines,
    'copyFilesIntoDocuments': copyFilesIntoDocuments,
    'opponentElo': opponentElo,
    'coverOnceIn': coverOnceIn,
    'explorer': explorer.toJson(),
    'puzzles': puzzles.toJson(),
    'autoAdvance': autoAdvance,
  });

  /// Reads [text]; a field that is missing or of the wrong type keeps its
  /// default, so a file from an older version still opens. Throws
  /// [FormatException] when the text is not a JSON object at all.
  factory Settings.fromJson(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('settings are not a JSON object');
    }
    T pick<T>(String key, T fallback) {
      final value = decoded[key];
      return value is T ? value : fallback;
    }

    return Settings(
      boardCoordinates: pick('boardCoordinates', defaults.boardCoordinates),
      engineCores: pick('engineCores', defaults.engineCores),
      engineMemoryMb: pick('engineMemoryMb', defaults.engineMemoryMb),
      engineLines: pick('engineLines', defaults.engineLines),
      copyFilesIntoDocuments: pick(
        'copyFilesIntoDocuments',
        defaults.copyFilesIntoDocuments,
      ),
      opponentElo: pick('opponentElo', defaults.opponentElo),
      coverOnceIn: pick('coverOnceIn', defaults.coverOnceIn),
      explorer: ExplorerChoice.fromJson(decoded['explorer']),
      puzzles: PuzzleFilter.fromJson(decoded['puzzles']),
      autoAdvance: pick('autoAdvance', defaults.autoAdvance),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.boardCoordinates == boardCoordinates &&
      other.engineCores == engineCores &&
      other.engineMemoryMb == engineMemoryMb &&
      other.engineLines == engineLines &&
      other.copyFilesIntoDocuments == copyFilesIntoDocuments &&
      other.opponentElo == opponentElo &&
      other.coverOnceIn == coverOnceIn &&
      other.explorer == explorer &&
      other.puzzles == puzzles &&
      other.autoAdvance == autoAdvance;

  @override
  int get hashCode => Object.hash(
    boardCoordinates,
    engineCores,
    engineMemoryMb,
    engineLines,
    copyFilesIntoDocuments,
    opponentElo,
    coverOnceIn,
    explorer,
    puzzles,
    autoAdvance,
  );
}
