/// What re-reading the repertoire file off disk actually changed.
///
/// "Reload" used to be a bare refresh icon that silently swapped the tree,
/// which gave the user no reason to ever press it. The summary is the reason:
/// it names the lines the file gained or lost since the app read it, so the
/// button answers "did anything change out there?" rather than just doing
/// invisible work.
library;

import '../../../models/repertoire_line.dart';

class RepertoireReloadSummary {
  const RepertoireReloadSummary({
    required this.added,
    required this.removed,
    required this.edited,
    required this.total,
    this.error,
  });

  /// Names of lines the file has now and did not have before.
  final List<String> added;

  /// Names of lines that were there before and are gone now.
  final List<String> removed;

  /// Lines whose moves are unchanged but whose PGN body is not — a comment,
  /// an annotation glyph, or a sub-variation edited outside the app.
  final int edited;

  /// Line count after the reload.
  final int total;

  /// Set when the reload itself failed; every other field is then meaningless.
  final String? error;

  bool get hasError => error != null;

  bool get unchanged =>
      !hasError && added.isEmpty && removed.isEmpty && edited == 0;

  const RepertoireReloadSummary.failed(String message)
    : added = const [],
      removed = const [],
      edited = 0,
      total = 0,
      error = message;

  /// Diffs two snapshots of the same repertoire.
  ///
  /// Lines are matched on their move sequence, not on [RepertoireLine.id] —
  /// ids are derived from a truncated move prefix and collide between lines
  /// that share a long opening, so id matching would report phantom churn on
  /// files where nothing moved.
  factory RepertoireReloadSummary.between(
    List<RepertoireLine> before,
    List<RepertoireLine> after,
  ) {
    final beforeByMoves = <String, List<RepertoireLine>>{};
    for (final line in before) {
      beforeByMoves.putIfAbsent(_signature(line), () => []).add(line);
    }

    final added = <String>[];
    var edited = 0;
    for (final line in after) {
      final bucket = beforeByMoves[_signature(line)];
      if (bucket == null || bucket.isEmpty) {
        added.add(_displayName(line));
        continue;
      }
      final match = bucket.removeAt(0);
      if (match.fullPgn.trim() != line.fullPgn.trim()) edited++;
    }

    final removed = [
      for (final bucket in beforeByMoves.values)
        for (final line in bucket) _displayName(line),
    ];

    return RepertoireReloadSummary(
      added: added,
      removed: removed,
      edited: edited,
      total: after.length,
    );
  }

  static String _signature(RepertoireLine line) =>
      '${line.color}|${line.moves.join(' ')}';

  static String _displayName(RepertoireLine line) {
    final name = line.name.trim();
    if (name.isNotEmpty) return name;
    final opening = line.moves.take(6).join(' ');
    return opening.isEmpty ? 'Untitled line' : opening;
  }
}
