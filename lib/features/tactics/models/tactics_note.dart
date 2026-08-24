/// The mistake note stored on a [TacticsPosition] — its one writer, its one
/// reader, and the rewrites that bring old notes to the current shape.
///
/// The note is a *wire format*, not a display string: the miner writes it,
/// the tactics PGN persists it as a move comment, and the trainer reads it
/// back to label the played move and annotate the solution's first move. The
/// two halves used to live apart — [formatEval] in the import pipeline, the
/// regex in the training panel widget — which is how three incompatible
/// formats ended up in the wild. They stay in this one file so a change to
/// either is a change to both.
///
/// Canonical form: `h5 +0.5 → -2.1, Qf3 +0.5` — the played move with the
/// eval it started from and the eval it reached, then the best move with the
/// eval it holds. The leading SAN and the trailing best-move clause are both
/// optional; the oldest generated notes have neither.
library;

import 'dart:math' as math;

import '../../../utils/pgn_comment_utils.dart' show filterDisplayComment;

/// A stored eval (`+0.5`, `-2.1`, `#3`, `#-4`).
const _evalPattern = r'(#-?\d+|[+-]?\d+(?:\.\d+)?)';

final _canonicalRe = RegExp(
  '^(?:([^\\s,]+)\\s+)?$_evalPattern\\s*→\\s*$_evalPattern'
  '(?:,\\s*([^\\s,]+)\\s+$_evalPattern)?\$',
);

/// Notes generated before July 2026 read "Blunder. Win chance dropped from
/// 69.2% to 48.9% (0.4%). Best was Qf3." — broken twice at display time:
/// `filterDisplayComment`'s Lichess-classification stripper eats
/// "Blunder. … 69." (stopping at the decimal point, leaving nonsense like
/// "2% to 48.9%"), the parenthesized delta is in winning-chance units, and
/// nobody thinks in win percentages anyway.
final _legacyPercentRe = RegExp(
  r'^(?:Blunder|Mistake|Inaccuracy)\. Win chance dropped from '
  r'(\d+(?:\.\d+)?)% to (\d+(?:\.\d+)?)% \(-?\d+(?:\.\d+)?%\)\.'
  r'(?: Best was (\S+?)\.?)?$',
);

/// One short-lived intermediate format also in the wild ("Blunder: h5
/// dropped your eval from +0.5 to -2.1 (win chance 55% → 21%). Best was
/// Qf3.") — evals already present, just verbose.
final _legacyVerboseRe = RegExp(
  r'^(?:Blunder|Mistake|Inaccuracy): (\S+) dropped your eval from '
  r'(\S+) to (\S+) \(win chance [^)]*\)\. Best was (\S+?)\.?$',
);

/// Inverse of the Lichess winning-chances formula: win percent → eval in
/// pawns ("+2.2"). The forward formula caps centipawns at ±1000, so the
/// recovered eval saturates at ±10.0.
String _evalFromWinPercent(double winPercent) {
  final wc = ((winPercent - 50) / 50).clamp(-0.999, 0.999);
  final cp = math.log((1 - wc) / (1 + wc)) / lichessWinChanceMultiplier;
  final pawns = (cp / 100).clamp(-10.0, 10.0);
  return '${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(1)}';
}

/// Lichess winning-chances multiplier (from scalachess). Shared with the
/// miner, which uses it forwards; [_evalFromWinPercent] inverts it.
/// https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/eval.scala
const double lichessWinChanceMultiplier = -0.00368208;

/// A generated tactic note, split so each half can be shown where it belongs.
class TacticsNote {
  const TacticsNote({
    required this.playedSan,
    required this.evalBefore,
    required this.evalAfter,
    required this.bestSan,
    required this.evalBest,
  });

  /// The move actually played. Empty in the oldest stored format.
  final String playedSan;

  /// Eval before the move — what was there to keep.
  final String evalBefore;

  /// Eval the played move reached, from the player's side.
  final String evalAfter;

  /// The move that should have been played. Empty when the note omits it.
  final String bestSan;

  /// Eval the best move holds. Equal to [evalBefore] for notes this app
  /// generates; kept separate because nothing guarantees that.
  final String evalBest;

  /// Human-readable engine eval: pawns with sign ("+0.5", "-2.1") or mate
  /// ("#3" delivering, "#-3" getting mated). Scores arrive in side-to-move
  /// perspective; pass [negate] when that side is the opponent so the number
  /// reads from the user's point of view.
  ///
  /// Deliberately *not* routed through `formatPackedEval`, despite looking
  /// like a near-duplicate. What this produces is written into notes that are
  /// persisted in the puzzle PGN and read back by [parse]. Sharing a display
  /// helper would let a cosmetic tweak (`#-3` → `-#3`, an extra decimal)
  /// silently invalidate every note already on disk.
  static String formatEval({
    int? scoreCp,
    int? scoreMate,
    bool negate = false,
  }) {
    if (scoreMate != null) {
      final mate = negate ? -scoreMate : scoreMate;
      return '#$mate';
    }
    final cp = negate ? -(scoreCp ?? 0) : (scoreCp ?? 0);
    final pawns = cp / 100.0;
    return '${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(1)}';
  }

  /// The note to store for a mined mistake, in canonical form.
  ///
  /// No prose: the mistake label already shows as ??/?/?!, and wordier
  /// phrasings collided with `filterDisplayComment`'s Lichess-classification
  /// stripper — which is what produced the legacy formats [canonicalize]
  /// still has to undo.
  static String compose({
    required String playedSan,
    required String evalBefore,
    required String evalAfter,
    required String bestSan,
  }) => '$playedSan $evalBefore → $evalAfter, $bestSan $evalBefore';

  /// Split a stored note into its parts, or null when [raw] is not a
  /// generated eval note (user prose, a scraped PGN comment).
  ///
  /// Total over every format this app has written: [canonicalize] rewrites
  /// the legacy ones first. Decoding a set canonicalizes too, so stored
  /// notes are upgraded on their next save — this is the safety net for
  /// anything that has not been through that yet.
  static TacticsNote? parse(String raw) {
    final m = _canonicalRe.firstMatch(_readable(raw));
    if (m == null) return null;
    return TacticsNote(
      playedSan: m.group(1) ?? '',
      evalBefore: m.group(2)!,
      evalAfter: m.group(3)!,
      bestSan: m.group(4) ?? '',
      evalBest: m.group(5) ?? m.group(2)!,
    );
  }

  /// Bring a stored note to the current format, once, at decode time — so
  /// everything downstream (and the file, after the next save) sees only the
  /// canonical shape. Notes that are already canonical, and notes that are
  /// not generated at all, come back untouched.
  static String canonicalize(String raw) {
    final trimmed = raw.trim();

    final percent = _legacyPercentRe.firstMatch(trimmed);
    if (percent != null) {
      final before = _evalFromWinPercent(double.parse(percent.group(1)!));
      final after = _evalFromWinPercent(double.parse(percent.group(2)!));
      // This format never recorded which move was played, so the canonical
      // note starts at the eval arc.
      final best = percent.group(3);
      return best == null
          ? '$before → $after'
          : '$before → $after, $best $before';
    }

    final verbose = _legacyVerboseRe.firstMatch(trimmed);
    if (verbose != null) {
      return compose(
        playedSan: verbose.group(1)!,
        evalBefore: verbose.group(2)!,
        evalAfter: verbose.group(3)!,
        bestSan: verbose.group(4)!,
      );
    }

    return raw;
  }

  /// The note ready for a note box: a generated note reduced to the played
  /// move and what it cost, anything else shown as written minus engine
  /// tokens.
  static String display(String raw) =>
      parse(raw)?.playedLabel ?? _readable(raw);

  /// Legacy shapes rewritten, engine tokens and scraped-PGN noise stripped.
  /// Stripping is a display concern, which is why [canonicalize] — whose
  /// output is persisted — does not do it.
  static String _readable(String raw) =>
      filterDisplayComment(canonicalize(raw)).trim();

  /// What the note box shows: one move and what it cost. The best move is not
  /// repeated here — it is the first move of the solution line right below,
  /// where its eval is shown next to it.
  ///
  /// Falls back to the eval arc for the oldest format, which never recorded
  /// which move was played; a bare `-0.1` on its own would say nothing.
  String get playedLabel =>
      playedSan.isEmpty ? '$evalBefore → $evalAfter' : '$playedSan $evalAfter';
}
