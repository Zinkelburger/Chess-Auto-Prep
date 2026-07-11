/// Shared SAN-token cleaning for PGN movetext fragments.
///
/// Several parsers accept loose movetext ("1. e4 e5 2. Nf3", "1.e4", root-move
/// prefixes, preview snippets) and need the bare SAN tokens. This helper is
/// the single implementation of that pipeline.
library;

final RegExp _moveNumberRe = RegExp(r'\d+\.+');
final RegExp _resultTokenRe = RegExp(r'(1-0|0-1|1/2-1/2|\*)');
final RegExp _whitespaceRe = RegExp(r'\s+');

/// Split loose PGN movetext into bare SAN tokens.
///
/// Strips:
/// - move numbers, including glued forms (`1.e4`, `3...Nf6`);
/// - game-result tokens (`1-0`, `0-1`, `1/2-1/2`, `*`);
/// - NAG tokens (`$3`).
///
/// Does NOT strip `{comments}` or `(variations)` — callers holding full PGN
/// must remove those first (they usually already do).
List<String> cleanSanTokens(String movetext) {
  if (movetext.trim().isEmpty) return const [];
  return movetext
      .replaceAll(_moveNumberRe, ' ')
      .replaceAll(_resultTokenRe, ' ')
      .split(_whitespaceRe)
      .where((t) => t.isNotEmpty && !t.startsWith(r'$'))
      .toList();
}
