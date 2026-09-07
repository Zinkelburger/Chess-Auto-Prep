/// How the board and the moves are drawn: coordinates on the board, and
/// whether a move reads `Nf3` or `♘f3`.
///
/// Both are device preferences with the same two homes lila gives them
/// (Preferences → Display): a setting here applies to every board and every
/// move list in the app, not to one screen. They live on a process singleton
/// like [EngineSettings]; widgets reach it through [BoardDisplaySettings.of],
/// which registers a rebuild dependency when a [DisplaySettingsScope] is
/// above them and falls back to the singleton (no rebuild on change) when
/// there is none — so a bare widget test needs no scaffolding.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/safe_change_notifier.dart';

/// Where the file letters and rank numbers go. Same four choices as lila.
enum BoardCoordinates {
  /// Nothing on the board.
  none,

  /// Letters along the bottom rank and numbers up the right-hand file, in
  /// the corner of the edge squares. The lila default.
  inside,

  /// Letters and numbers in a margin around the squares.
  outside,

  /// Every square carries its own name. For learning the board.
  everySquare;

  static BoardCoordinates fromStorage(String? value) =>
      BoardCoordinates.values.firstWhere(
        (c) => c.name == value,
        orElse: () => BoardCoordinates.inside,
      );
}

/// How a piece is written in a move.
enum PieceNotation {
  /// `K Q R B N`, as in a PGN.
  letters,

  /// `♔ ♕ ♖ ♗ ♘`.
  figurines;

  static PieceNotation fromStorage(String? value) => PieceNotation.values
      .firstWhere((n) => n.name == value, orElse: () => PieceNotation.letters);
}

class BoardDisplaySettings extends ChangeNotifier with SafeChangeNotifier {
  BoardDisplaySettings._();
  static final BoardDisplaySettings instance = BoardDisplaySettings._();

  /// A settings object of its own for tests and previews.
  @visibleForTesting
  BoardDisplaySettings.fresh({
    BoardCoordinates coordinates = BoardCoordinates.inside,
    PieceNotation pieceNotation = PieceNotation.letters,
  }) {
    _coordinates = coordinates;
    _pieceNotation = pieceNotation;
  }

  static const _keyCoordinates = 'display.board_coordinates';
  static const _keyPieceNotation = 'display.piece_notation';

  BoardCoordinates _coordinates = BoardCoordinates.inside;
  PieceNotation _pieceNotation = PieceNotation.letters;

  BoardCoordinates get coordinates => _coordinates;
  PieceNotation get pieceNotation => _pieceNotation;

  /// The settings in effect for [context]: the nearest [DisplaySettingsScope]
  /// (rebuilding the caller when they change), else [instance].
  static BoardDisplaySettings of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DisplaySettingsScope>();
    return scope?.notifier ?? instance;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _coordinates = BoardCoordinates.fromStorage(
      prefs.getString(_keyCoordinates),
    );
    _pieceNotation = PieceNotation.fromStorage(
      prefs.getString(_keyPieceNotation),
    );
    notifyListeners();
  }

  Future<void> setCoordinates(BoardCoordinates value) async {
    if (_coordinates == value) return;
    _coordinates = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCoordinates, value.name);
  }

  Future<void> setPieceNotation(PieceNotation value) async {
    if (_pieceNotation == value) return;
    _pieceNotation = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPieceNotation, value.name);
  }

  Future<void> resetToDefaults() async {
    _coordinates = BoardCoordinates.inside;
    _pieceNotation = PieceNotation.letters;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCoordinates);
    await prefs.remove(_keyPieceNotation);
  }
}

/// Puts a [BoardDisplaySettings] in the tree so [BoardDisplaySettings.of]
/// can rebuild boards and move lists when a preference changes. One sits
/// above the app; tests may plant another with [BoardDisplaySettings.fresh].
class DisplaySettingsScope extends InheritedNotifier<BoardDisplaySettings> {
  const DisplaySettingsScope({
    super.key,
    required BoardDisplaySettings settings,
    required super.child,
  }) : super(notifier: settings);
}
