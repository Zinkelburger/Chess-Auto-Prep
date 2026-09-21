/// The part of a PGN comment a person reads: the text without `[%...]`
/// machine tokens (engine evals, clocks, arrows and this app's own
/// statistics such as `[%score 46.4%]`).
///
/// This is the one definition of "prose" in v2. A comment is kept whole in
/// the tree so it round-trips byte for byte; only display strips tokens.
/// dartchess's `PgnComment` is not used because it knows only the standard
/// tokens and would keep `[%score]` as text.
String displayComment(String comment) =>
    comment.replaceAll(_machineToken, ' ').replaceAll(_whitespace, ' ').trim();

/// The `[%...]` tokens of [comment] in the order it has them, space
/// separated; empty when it has none.
String machineTokens(String comment) =>
    _machineToken.allMatches(comment).map((m) => m[0]!).join(' ');

/// [comment] with its prose replaced by [prose], keeping the machine tokens
/// it carried.
///
/// A person edits the words; the engine's evaluation, its line and the
/// clock belong to the move and must survive that edit. Clearing the prose
/// leaves the tokens alone, and a comment that ends up with nothing in it
/// is removed rather than written as `{}`.
String? withProse(String? comment, String? prose) {
  final tokens = machineTokens(comment ?? '');
  final text = prose?.trim() ?? '';
  if (text.isEmpty) return tokens.isEmpty ? null : tokens;
  return tokens.isEmpty ? text : '$text $tokens';
}

/// Whether [comment] carries the bare machine token [name], such as
/// `tstart`. Tokens are what a marker on a move is: they travel with the
/// comment, survive a round trip and are hidden from the prose.
bool hasToken(String? comment, String name) =>
    (comment ?? '').contains('[%$name]');

/// [comment] with the bare token [name] added or taken away, keeping its
/// prose and its other tokens. A comment left with nothing in it is removed
/// rather than written as `{}`.
String? withToken(String? comment, String name, {required bool present}) {
  final token = '[%$name]';
  final text = comment ?? '';
  if (text.contains(token) == present) return comment;
  final next = present
      ? (text.trim().isEmpty ? token : '${text.trim()} $token')
      : text.split(token).join(' ').replaceAll(_runOfSpaces, ' ').trim();
  return next.isEmpty ? null : next;
}

/// Why [text] cannot be a comment in a PGN file, or null when it can be.
///
/// A comment ends at its first `}` and the format gives no way to escape
/// one: the old app and Lichess both strip braces rather than invent an
/// escape. So a `}` in the words would cut the comment — and every move
/// written after it — out of the file. Saying no is the only honest answer.
String? commentRefusal(String text) =>
    text.contains('}') ? 'a comment cannot hold a closing brace' : null;

final _machineToken = RegExp(r'\[%[^\]]*\]');
final _whitespace = RegExp(r'\s+');
final _runOfSpaces = RegExp(' {2,}');

/// The glyph for a numeric annotation, or null for the ones nobody prints.
String? nagGlyph(int nag) => switch (nag) {
  1 => '!',
  2 => '?',
  3 => '!!',
  4 => '??',
  5 => '!?',
  6 => '?!',
  _ => null,
};
