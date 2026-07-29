/// Pure movetext helpers for the Games feature.
///
/// Downloaded games carry clock/eval brace comments and (rarely) variations;
/// the deviation walker and the move-count column only want the mainline SAN
/// tokens. Pure and top-level so batches can run through `compute`.
library;

/// Extract the mainline SAN tokens of a single-game PGN, in order.
///
/// Strips headers, brace comments, nested variations, NAGs, move numbers and
/// the result token. Check/mate suffixes stay on the SAN (matching is
/// suffix-insensitive where it matters).
List<String> extractMainlineSans(String pgn) {
  final buf = StringBuffer();
  var inHeaders = true;
  for (final raw in pgn.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (inHeaders && line.startsWith('[')) continue;
    inHeaders = false;
    buf
      ..write(line)
      ..write(' ');
  }
  // Brace comments never nest per the PGN spec.
  var text = buf.toString().replaceAll(RegExp(r'\{[^}]*\}'), ' ');

  // Variations do nest — depth-count instead of a regex.
  final sb = StringBuffer();
  var depth = 0;
  for (final rune in text.runes) {
    if (rune == 0x28) {
      depth++;
    } else if (rune == 0x29) {
      if (depth > 0) depth--;
    } else if (depth == 0) {
      sb.writeCharCode(rune);
    }
  }
  text = sb.toString();

  final sans = <String>[];
  for (final token in text.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (token == '1-0' ||
        token == '0-1' ||
        token == '1/2-1/2' ||
        token == '*') {
      continue;
    }
    if (token.startsWith(r'$')) continue;
    // "12." / "12..." alone, or glued to the move ("12.e4", "12...c5").
    final unglued = token.replaceFirst(RegExp(r'^\d+\.+'), '');
    if (unglued.isEmpty || RegExp(r'^\.+$').hasMatch(unglued)) continue;
    sans.add(unglued);
  }
  return sans;
}

/// Batch form for `compute`: one SAN list per input PGN.
List<List<String>> extractMainlineSansBatch(List<String> pgns) => [
  for (final pgn in pgns) extractMainlineSans(pgn),
];

/// SAN with check/mate suffixes removed, for tolerance-matched comparison
/// ("Nf3+" in a game must hit "Nf3" in a repertoire and vice versa).
String normalizeSan(String san) => san.replaceAll(RegExp(r'[+#]+$'), '');
