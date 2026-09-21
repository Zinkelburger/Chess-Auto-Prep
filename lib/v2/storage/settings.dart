import 'dart:convert';

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

  static const defaults = Settings();

  /// The most the engine rows accept: a table bigger than this or more
  /// lines than this is a tuning job, not a setting.
  static const maxMemoryMb = 4096;
  static const maxLines = 8;

  Settings copyWith({
    bool? boardCoordinates,
    int? engineCores,
    int? engineMemoryMb,
    int? engineLines,
    bool? copyFilesIntoDocuments,
  }) => Settings(
    boardCoordinates: boardCoordinates ?? this.boardCoordinates,
    engineCores: engineCores ?? this.engineCores,
    engineMemoryMb: engineMemoryMb ?? this.engineMemoryMb,
    engineLines: engineLines ?? this.engineLines,
    copyFilesIntoDocuments:
        copyFilesIntoDocuments ?? this.copyFilesIntoDocuments,
  );

  /// The file's text. One flat object with plain names, so a person can
  /// read it and the old app's keys never collide with it.
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'boardCoordinates': boardCoordinates,
    'engineCores': engineCores,
    'engineMemoryMb': engineMemoryMb,
    'engineLines': engineLines,
    'copyFilesIntoDocuments': copyFilesIntoDocuments,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.boardCoordinates == boardCoordinates &&
      other.engineCores == engineCores &&
      other.engineMemoryMb == engineMemoryMb &&
      other.engineLines == engineLines &&
      other.copyFilesIntoDocuments == copyFilesIntoDocuments;

  @override
  int get hashCode => Object.hash(
    boardCoordinates,
    engineCores,
    engineMemoryMb,
    engineLines,
    copyFilesIntoDocuments,
  );
}
