/// The `// Color:` / `// Root:` block a repertoire file carries above its
/// first `[Event]` tag.
///
/// Only produced when the PGN actually parsed; a missing file, a read failure
/// or a tree-build error leaves it null, which tells the caller to keep the
/// headers it already had.
class RepertoireHeaders {
  const RepertoireHeaders({
    required this.rootMoves,
    required this.isWhite,
    required this.needsColorSelection,
  });

  /// Movetext of the saved root position (`// Root:`), empty when unset.
  final String rootMoves;

  /// Whether this is a White repertoire. Anything but `// Color: Black`
  /// (case-insensitive, as `extractRepertoireColor` reads it) — including a
  /// missing header — reads as White.
  final bool isWhite;

  /// True when the file carried no `// Color:` header at all, so the user
  /// still has to pick a side.
  final bool needsColorSelection;
}

/// Reads the `// Color:` / `// Root:` comment block off [pgnText].
///
/// A file with no `// Color:` line is not automatically a question for the
/// user: a repertoire this app generated says whose it is in its own first
/// `[Event]` tag ("… : Repertoire for Black", written by
/// [CourseTitles.courseTitle]), and an imported course usually says the same
/// thing in the same words. Reading it there is strictly better than asking,
/// because the file is the authority and the user is guessing at what is in
/// it.
RepertoireHeaders parseRepertoireHeaders(String pgnText) {
  String? color;
  String? rootMoves;
  bool? inferred;
  // The block lives above the first game — [upsertMetadataComment] puts it
  // there — so the scan stops at the first `[Event ` line instead of
  // splitting the whole file into lines to look at its top.
  var lineStart = 0;
  while (lineStart <= pgnText.length) {
    var lineEnd = pgnText.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = pgnText.length;
    final trimmed = pgnText.substring(lineStart, lineEnd).trim();
    lineStart = lineEnd + 1;
    if (trimmed.startsWith('// Color:')) {
      color = trimmed.substring(9).trim();
    } else if (trimmed.startsWith('// Root:')) {
      rootMoves = trimmed.substring(8).trim();
    } else if (trimmed.startsWith('[Event ')) {
      inferred = _colorFromEventTag(trimmed);
      break;
    }
  }
  return RepertoireHeaders(
    rootMoves: rootMoves ?? '',
    // Case-insensitive to match `extractRepertoireColor`, which every other
    // reader of this line uses; the Builder and the Trainer must agree on
    // whose file this is.
    isWhite: color != null
        ? color.toLowerCase() != 'black'
        : (inferred ?? true),
    // Only ask when neither the comment nor the file's own title says.
    needsColorSelection: color == null && inferred == null,
  );
}

/// Whose repertoire an `[Event ...]` tag says it is, or null when it does not
/// say. Matches the phrasing this app writes and the one Chessable-style
/// course exports use; anything else stays null rather than guessing from,
/// say, an opening name that merely sounds like a defence.
bool? _colorFromEventTag(String eventLine) {
  final lower = eventLine.toLowerCase();
  final white = lower.contains('for white');
  final black = lower.contains('for black');
  // Both, or neither, is not evidence.
  if (white == black) return null;
  return white;
}

/// Replaces the `$prefix ...` comment line in [content], or inserts one above
/// the first `[Event ]` tag (or at the very top when there is none).
///
/// Duplicates collapse: every later line with the same prefix is dropped.
String upsertMetadataComment(String content, String prefix, String value) {
  final lines = content.split('\n');
  final updated = <String>[];
  var inserted = false;

  for (final line in lines) {
    final trimmed = line.trim();

    if (trimmed.startsWith(prefix)) {
      if (!inserted) {
        updated.add('$prefix $value');
        inserted = true;
      }
      continue;
    }

    if (!inserted && trimmed.startsWith('[Event ')) {
      updated.add('$prefix $value');
      inserted = true;
    }

    updated.add(line);
  }

  if (!inserted) {
    updated.insert(0, '$prefix $value');
  }

  return updated.join('\n');
}
