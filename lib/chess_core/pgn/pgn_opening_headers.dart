/// Filling `ECO` / `Opening` tags on parsed games from the bundled book.
library;

import '../../models/pgn_game_entry.dart';
import '../../models/pgn_filter_models.dart';
import '../../utils/pgn_utils.dart';
import 'opening_book.dart';
import 'mainline_lexer.dart' show movetextStart;
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart'
    show buildFenIndex;

/// The two tags the opening book can fill.
const List<String> _openingTags = ['ECO', 'Opening'];

/// A tag value that names nothing: absent, blank, or the PGN `?` placeholder.
bool _isPlaceholder(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty || trimmed == '?';
}

/// Fill missing tags without reserializing moves, comments or variations.
/// Existing non-placeholder values are the source's authoritative labels.
///
/// Returns whether [game] was changed.
bool fillOpeningHeaders(PgnGameEntry game, OpeningBookEntry opening) {
  var changed = false;
  for (final tag in {'ECO': opening.eco, 'Opening': opening.name}.entries) {
    if (!_isPlaceholder(game.headers[tag.key])) continue;
    game.pgnText = _withHeader(game.pgnText, tag.key, tag.value);
    game.headers[tag.key] = tag.value;
    changed = true;
  }
  return changed;
}

/// [text] with its `[key "..."]` header set to [value]: replaced in place
/// when present, appended to the header block otherwise. The movetext is
/// copied through untouched.
String _withHeader(String text, String key, String value) {
  final boundary = movetextStart(text).clamp(0, text.length);
  final headers = text.substring(0, boundary).trimRight();
  final line = '[$key "${escapeHeaderValue(value)}"]';
  final pattern = RegExp('\\[$key\\s+"(?:[^"\\\\]|\\\\.)*"\\s*\\]');
  final updated = pattern.hasMatch(headers)
      ? headers.replaceFirst(pattern, line)
      : headers.isEmpty
      ? line
      : '$headers\n$line';
  return '$updated\n\n${text.substring(boundary)}';
}

/// Whether [game] lacks an `ECO` or `Opening` tag worth keeping.
bool needsOpeningHeaders(PgnGameEntry game) =>
    _openingTags.any((tag) => _isPlaceholder(game.headers[tag]));

/// Annotation sidelines must never determine the opening of a played game.
List<OpeningBookEntry?> classifyMainlineOpenings(
  ({OpeningBook book, List<GameRecord> games}) request,
) => classifyGamesFromIndex(
  request.book,
  buildFenIndex(request.games, includeVariations: false),
  request.games.length,
);
