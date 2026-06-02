/// Lightweight game row for navigation UI (nav bar + search dialog).
library;

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
}
