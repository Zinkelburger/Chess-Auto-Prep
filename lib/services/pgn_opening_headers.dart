import '../models/pgn_game_entry.dart';
import '../models/pgn_filter_models.dart';
import '../utils/pgn_utils.dart';
import 'opening_book_service.dart';
import 'pgn_parsing_service.dart' show movetextStart, buildFenIndex;

/// Fill missing tags without reserializing moves, comments or variations.
/// Existing non-placeholder values are the source's authoritative labels.
bool fillOpeningHeaders(PgnGameEntry game, OpeningBookEntry opening) {
  var changed = false;
  for (final tag in {'ECO': opening.eco, 'Opening': opening.name}.entries) {
    final old = game.headers[tag.key]?.trim() ?? '';
    if (old.isNotEmpty && old != '?') continue;
    final text = game.pgnText;
    final boundary = movetextStart(text).clamp(0, text.length);
    var headers = text.substring(0, boundary).trimRight();
    final line = '[${tag.key} "${escapeHeaderValue(tag.value)}"]';
    final pattern = RegExp('\\[${tag.key}\\s+"(?:[^"\\\\]|\\\\.)*"\\s*\\]');
    headers = pattern.hasMatch(headers)
        ? headers.replaceFirst(pattern, line)
        : headers.isEmpty
        ? line
        : '$headers\n$line';
    game.pgnText = '$headers\n\n${text.substring(boundary)}';
    game.headers[tag.key] = tag.value;
    changed = true;
  }
  return changed;
}

bool needsOpeningHeaders(PgnGameEntry game) => ['ECO', 'Opening'].any((tag) {
  final value = game.headers[tag]?.trim() ?? '';
  return value.isEmpty || value == '?';
});

/// Annotation sidelines must never determine the opening of a played game.
List<OpeningBookEntry?> classifyMainlineOpenings(
  ({OpeningBook book, List<GameRecord> games}) request,
) => classifyGamesFromIndex(
  request.book,
  buildFenIndex(request.games, includeVariations: false),
  request.games.length,
);
