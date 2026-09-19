/// The part of a PGN comment a person reads: the text without `[%...]`
/// machine tokens (engine evals, clocks, arrows and this app's own
/// statistics such as `[%score 46.4%]`).
String displayComment(String comment) =>
    comment.replaceAll(_machineToken, ' ').replaceAll(_whitespace, ' ').trim();

final _machineToken = RegExp(r'\[%[^\]]*\]');
final _whitespace = RegExp(r'\s+');

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
