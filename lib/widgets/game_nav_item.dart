/// Lightweight game row for navigation UI (nav bar + search dialog).
library;

import '../models/pgn_game_entry.dart';

class GameNavItem {
  final String label;
  final int studyRating;
  final String studySummary;
  final Map<String, String> headers;

  const GameNavItem({
    required this.label,
    required this.studyRating,
    this.studySummary = '',
    this.headers = const {},
  });

  factory GameNavItem.fromEntry(PgnGameEntry game) => GameNavItem(
    label: game.label,
    studyRating: game.studyRating,
    studySummary: game.studySummary,
    headers: game.headers,
  );
}
