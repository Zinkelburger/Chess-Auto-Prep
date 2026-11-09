/// Where the window was when the app was last used: the mode by its name,
/// and the file on the board, if one was. Kept in the settings so the next
/// launch opens there rather than on an empty board.
final class SavedPlace {
  const SavedPlace({required this.mode, this.path, this.section, this.game});

  final String mode;

  /// The file on the board, absolute; null for an analysis board or a mode
  /// with no board.
  final String? path;

  /// The `[ChapterName]` of a course file's chapter.
  final String? section;

  /// The game of a file read game by game.
  final int? game;

  Map<String, Object?> toJson() => {
    'mode': mode,
    'path': ?path,
    'section': ?section,
    'game': ?game,
  };

  /// A place read back, or null when [json] is not one.
  static SavedPlace? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final mode = json['mode'];
    final path = json['path'];
    final section = json['section'];
    final game = json['game'];
    if (mode is! String) return null;
    return SavedPlace(
      mode: mode,
      path: path is String ? path : null,
      section: section is String ? section : null,
      game: game is int && game >= 0 ? game : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedPlace &&
      other.mode == mode &&
      other.path == path &&
      other.section == section &&
      other.game == game;

  @override
  int get hashCode => Object.hash(mode, path, section, game);
}
