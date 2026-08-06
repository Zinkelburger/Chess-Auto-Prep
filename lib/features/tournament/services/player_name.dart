/// Name normalization for joining entry lists against the player directory.
///
/// Entry lists and the USCF directory disagree about almost everything except
/// the letters: the directory stores `First [Middle] Last` with no commas and
/// ~14% of rows in ALL CAPS (`VIDIP KUMAR KONA` sits next to
/// `Justin Weicheng Zhang`), while tournament entry lists usually publish
/// `Last, First`. Both forms have to collapse to the same key.
///
/// Joining on USCF ID is exact and should always be preferred; this is the
/// fallback for lists that publish names only.
library;

/// Generational suffixes that are never part of the surname we match on.
const _suffixes = {'JR', 'SR', 'II', 'III', 'IV', 'V'};

/// Punctuation that differs freely between sources and carries no signal:
/// `O'Brien` / `OBrien`, `St. John` / `St John`.
///
/// The hyphen is deliberately *not* in this set — it is handled per part,
/// because it means opposite things on either side of a name.
final _punctuation = RegExp(r"[.,'’_]");
final _whitespace = RegExp(r'\s+');
final _hyphen = RegExp(r'-');

/// A name split into the two parts we are willing to match on.
class ParsedName {
  final String first;
  final String last;

  const ParsedName(this.first, this.last);

  /// The join key: `FIRST|LAST`, both normalized.
  ///
  /// Middle names are deliberately dropped — they appear inconsistently
  /// across sources and their absence is not evidence of a different person.
  String get key => '$first|$last';

  /// Looser key for candidate generation when the exact key misses.
  String get lastKey => last;

  bool get isEmpty => first.isEmpty && last.isEmpty;
}

/// Normalize a raw name into a matchable [ParsedName].
///
/// Handles both `Last, First Middle` and `First Middle Last`. Without a comma,
/// a multi-word surname (`Jan Van Der Berg`) resolves to its final token
/// (`BERG`) — imperfect, but the alternative is guessing at particles, and the
/// comma form (which entry lists usually use) parses those correctly.
///
/// Hyphens are treated asymmetrically, because they mean different things on
/// either side of the name. In a surname a hyphen joins one indivisible unit
/// (`Smith-Jones` is the whole surname, so it becomes `SMITHJONES`). In a
/// given name it separates two names of which only the first is load-bearing
/// here, exactly like a space would (`Anne-Marie` becomes `ANNE`, matching how
/// `Anne Marie` is handled once the middle name is dropped).
ParsedName parsePlayerName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const ParsedName('', '');

  String firstPart;
  String lastPart;

  final comma = trimmed.indexOf(',');
  if (comma >= 0) {
    // `Van Der Berg, Jan` — everything before the comma is the surname, so
    // particles stay attached.
    lastPart = trimmed.substring(0, comma);
    firstPart = trimmed.substring(comma + 1);
  } else {
    final tokens = _rawTokens(trimmed);
    if (tokens.isEmpty) return const ParsedName('', '');
    if (tokens.length == 1) return ParsedName('', _joinSurname(tokens));
    lastPart = tokens.last;
    firstPart = tokens.first;
  }

  return ParsedName(
    _leadingGivenName(firstPart),
    _joinSurname(_rawTokens(lastPart)),
  );
}

/// The `FIRST|LAST` join key for [raw]. Convenience over [parsePlayerName].
String playerNameKey(String raw) => parsePlayerName(raw).key;

/// First given name only: the first whitespace- *or* hyphen-separated unit.
String _leadingGivenName(String part) {
  final tokens = _rawTokens(part);
  if (tokens.isEmpty) return '';
  final head = tokens.first.split(_hyphen).where((t) => t.isNotEmpty);
  return head.isEmpty ? '' : head.first;
}

/// A surname joined into one unit, with hyphens absorbed.
String _joinSurname(List<String> tokens) =>
    tokens.join().replaceAll(_hyphen, '');

/// Uppercase, strip punctuation (keeping hyphens), drop generational
/// suffixes, split on whitespace.
List<String> _rawTokens(String s) {
  final cleaned = s
      .toUpperCase()
      .replaceAll(_punctuation, '')
      .replaceAll(_whitespace, ' ')
      .trim();
  if (cleaned.isEmpty) return const [];

  final tokens = cleaned.split(' ').where((t) => t.isNotEmpty).toList();
  // Only strip a suffix when something would remain — a player whose entire
  // listed name is "V" should keep it.
  while (tokens.length > 1 && _suffixes.contains(tokens.last)) {
    tokens.removeLast();
  }
  return tokens;
}
