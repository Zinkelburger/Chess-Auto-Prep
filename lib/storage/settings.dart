import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;

import '../chess/explorer_choice.dart';
import '../chess/training/training_options.dart';
import '../chess/tactics/game_ids.dart' show GameSpeed;
import '../chess/tactics/puzzle_queue.dart';
import 'update_choices.dart';

/// What the user has chosen about the app as a whole: the few things two
/// reasonable people want different values for and the app cannot tell.
///
/// Everything else is a decision made in code, a thing a mode remembers
/// for itself, or configuration that travels with a job. A row is added
/// here only when something reads it.
final class Settings {
  const Settings({
    this.boardCoordinates = true,
    this.figurines = false,
    this.tournamentFinalPositions = true,
    this.engineCores = 1,
    this.engineMemoryMb = 128,
    this.engineLines = 3,
    this.engineThreat = false,
    this.copyFilesIntoDocuments = true,
    this.opponentElo = 2200,
    this.coverOnceIn = 50,
    this.explorer = ExplorerChoice.defaults,
    this.puzzles = PuzzleFilter.defaults,
    this.autoAdvance = true,
    this.acceptAlternativeAnswers = false,
    this.training = TrainingOptions.defaults,
    this.myGameSpeeds = allSpeeds,
    this.updates = UpdateChoices.defaults,
    this._extra = const {},
  });

  /// Rank and file letters on the board.
  final bool boardCoordinates;

  /// Moves written with piece figurines (`♘f3`) instead of letters
  /// (`Nf3`) wherever the app shows them. Files keep the letters.
  final bool figurines;
  final bool tournamentFinalPositions;

  /// Threads the workspace engine may use.
  final int engineCores;

  /// The engine's hash table, in megabytes.
  final int engineMemoryMb;

  /// How many lines the engine pane shows.
  final int engineLines;

  /// Whether the engine also shows what the side not to move threatens, as
  /// a red arrow on the board. Turned on and off in the engine pane.
  final bool engineThreat;

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

  /// Ask Stockfish before rejecting a legal, non-stored puzzle move.
  final bool acceptAlternativeAnswers;

  final TrainingOptions training;

  /// The time controls of the user's games that Tactics mines and My games
  /// checks against the book. Never empty.
  final Set<GameSpeed> myGameSpeeds;

  static const allSpeeds = {
    GameSpeed.bullet,
    GameSpeed.blitz,
    GameSpeed.rapid,
    GameSpeed.classical,
  };

  /// The update switches, the last check and the skipped version.
  final UpdateChoices updates;

  /// The file's keys this build does not read, written back as they were
  /// so a newer build's choices survive an older build saving. Not part of
  /// equality: nothing on screen can change them.
  final Map<String, Object?> _extra;

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
    bool? figurines,
    bool? tournamentFinalPositions,
    int? engineCores,
    int? engineMemoryMb,
    int? engineLines,
    bool? engineThreat,
    bool? copyFilesIntoDocuments,
    int? opponentElo,
    int? coverOnceIn,
    ExplorerChoice? explorer,
    PuzzleFilter? puzzles,
    bool? autoAdvance,
    bool? acceptAlternativeAnswers,
    TrainingOptions? training,
    Set<GameSpeed>? myGameSpeeds,
    UpdateChoices? updates,
  }) => Settings(
    boardCoordinates: boardCoordinates ?? this.boardCoordinates,
    figurines: figurines ?? this.figurines,
    tournamentFinalPositions:
        tournamentFinalPositions ?? this.tournamentFinalPositions,
    engineCores: engineCores ?? this.engineCores,
    engineMemoryMb: engineMemoryMb ?? this.engineMemoryMb,
    engineLines: engineLines ?? this.engineLines,
    engineThreat: engineThreat ?? this.engineThreat,
    copyFilesIntoDocuments:
        copyFilesIntoDocuments ?? this.copyFilesIntoDocuments,
    opponentElo: opponentElo ?? this.opponentElo,
    coverOnceIn: coverOnceIn ?? this.coverOnceIn,
    explorer: explorer ?? this.explorer,
    puzzles: puzzles ?? this.puzzles,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    acceptAlternativeAnswers:
        acceptAlternativeAnswers ?? this.acceptAlternativeAnswers,
    training: training ?? this.training,
    myGameSpeeds: myGameSpeeds ?? this.myGameSpeeds,
    updates: updates ?? this.updates,
    extra: _extra,
  );

  /// The file's text. One flat object with plain names, so a person can
  /// read it and the old app's keys never collide with it.
  String toJson() => const JsonEncoder.withIndent('  ').convert({
    ..._extra,
    'boardCoordinates': boardCoordinates,
    'figurines': figurines,
    'tournamentFinalPositions': tournamentFinalPositions,
    'engineCores': engineCores,
    'engineMemoryMb': engineMemoryMb,
    'engineLines': engineLines,
    'engineThreat': engineThreat,
    'copyFilesIntoDocuments': copyFilesIntoDocuments,
    'opponentElo': opponentElo,
    'coverOnceIn': coverOnceIn,
    'explorer': explorer.toJson(),
    'puzzles': puzzles.toJson(),
    'autoAdvance': autoAdvance,
    'acceptAlternativeAnswers': acceptAlternativeAnswers,
    'training': training.toJson(),
    'myGameSpeeds': [
      for (final speed in GameSpeed.values)
        if (myGameSpeeds.contains(speed)) speed.name,
    ],
    'updates': updates.toJson(),
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
      figurines: pick('figurines', defaults.figurines),
      tournamentFinalPositions: pick(
        'tournamentFinalPositions',
        defaults.tournamentFinalPositions,
      ),
      engineCores: pick('engineCores', defaults.engineCores),
      engineMemoryMb: pick('engineMemoryMb', defaults.engineMemoryMb),
      engineLines: pick('engineLines', defaults.engineLines),
      engineThreat: pick('engineThreat', defaults.engineThreat),
      copyFilesIntoDocuments: pick(
        'copyFilesIntoDocuments',
        defaults.copyFilesIntoDocuments,
      ),
      opponentElo: pick('opponentElo', defaults.opponentElo),
      coverOnceIn: pick('coverOnceIn', defaults.coverOnceIn),
      explorer: ExplorerChoice.fromJson(decoded['explorer']),
      puzzles: PuzzleFilter.fromJson(decoded['puzzles']),
      autoAdvance: pick('autoAdvance', defaults.autoAdvance),
      acceptAlternativeAnswers: pick(
        'acceptAlternativeAnswers',
        defaults.acceptAlternativeAnswers,
      ),
      training: TrainingOptions.fromJson(decoded['training']),
      myGameSpeeds: _speeds(decoded['myGameSpeeds']),
      updates: UpdateChoices.fromJson(decoded['updates']),
      extra: {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (!_keys.contains(key)) key: value,
      },
    );
  }

  /// Every top-level key [toJson] writes.
  static const _keys = {
    'boardCoordinates',
    'figurines',
    'tournamentFinalPositions',
    'engineCores',
    'engineMemoryMb',
    'engineLines',
    'engineThreat',
    'copyFilesIntoDocuments',
    'opponentElo',
    'coverOnceIn',
    'explorer',
    'puzzles',
    'autoAdvance',
    'acceptAlternativeAnswers',
    'training',
    'myGameSpeeds',
    'updates',
  };

  /// The speeds [value] names; every speed when it names none, since no
  /// games at all is not a choice anyone makes.
  static Set<GameSpeed> _speeds(Object? value) {
    final names = value is List
        ? value.whereType<String>().toSet()
        : <String>{};
    final speeds = {
      for (final speed in GameSpeed.values)
        if (names.contains(speed.name)) speed,
    };
    return speeds.isEmpty ? allSpeeds : speeds;
  }

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.boardCoordinates == boardCoordinates &&
      other.figurines == figurines &&
      other.tournamentFinalPositions == tournamentFinalPositions &&
      other.engineCores == engineCores &&
      other.engineMemoryMb == engineMemoryMb &&
      other.engineLines == engineLines &&
      other.engineThreat == engineThreat &&
      other.copyFilesIntoDocuments == copyFilesIntoDocuments &&
      other.opponentElo == opponentElo &&
      other.coverOnceIn == coverOnceIn &&
      other.explorer == explorer &&
      other.puzzles == puzzles &&
      other.autoAdvance == autoAdvance &&
      other.acceptAlternativeAnswers == acceptAlternativeAnswers &&
      other.training == training &&
      setEquals(other.myGameSpeeds, myGameSpeeds) &&
      other.updates == updates;

  @override
  int get hashCode => Object.hash(
    boardCoordinates,
    figurines,
    tournamentFinalPositions,
    engineCores,
    engineMemoryMb,
    engineLines,
    engineThreat,
    copyFilesIntoDocuments,
    opponentElo,
    coverOnceIn,
    explorer,
    puzzles,
    autoAdvance,
    acceptAlternativeAnswers,
    training,
    Object.hashAllUnordered(myGameSpeeds),
    updates,
  );
}
