/// The moments in a game worth a second look, as the game card shows them:
/// where it left the book, and each of my mistakes.
///
/// A card used to say "Left book at move 9" and "1 2 0" — a sentence about a
/// position and three counts. Neither tells you *where*; you had to open the
/// game and scrub for it. A moment is the position itself, the move drawn on
/// it, and the ply to land on when it is clicked. Pure: no widgets, no IO —
/// the card turns the UCI strings into arrows.
library;

import 'package:dartchess/dartchess.dart' show Chess;

import '../../../core/app_state.dart' show PgnViewerTab;
import '../../../services/game_analysis_controller.dart'
    show MoveClassification;
import '../../../utils/chess_utils.dart'
    show fenAfterMoves, formatEvalDisplay, sanToUci;
import '../../../utils/movetext_builder.dart' show formatMoveAtPly;
import '../models/recent_game.dart';
import 'game_deviation_service.dart';
import 'game_review_summary.dart';

class GameMoment {
  const GameMoment({
    required this.ply,
    required this.fen,
    required this.playedUci,
    required this.wantedUcis,
    required this.byMe,
    required this.title,
    required this.detail,
    required this.tooltip,
    required this.tab,
    this.classification,
  });

  /// Mainline index *after* the move — where the viewer lands on open.
  final int ply;

  /// The position the move was played in.
  final String fen;

  /// The move that was played, or empty when the SAN did not parse there.
  final String playedUci;

  /// What the book (or the stored engine line) wanted instead.
  final List<String> wantedUcis;

  /// Whether [playedUci] was my move.
  final bool byMe;

  /// The move with its number: "23. Nxe5?" / "9... Bd3".
  final String title;

  /// One short line under it: "Blunder −3.2" / "You left book".
  final String detail;
  final String tooltip;
  final PgnViewerTab tab;

  /// Set for mistake moments; drives the arrow's hue.
  final MoveClassification? classification;
}

/// Every moment of [game], in game order. Empty until the book check and
/// the review have run — the card then shows no strip at all.
List<GameMoment> buildGameMoments(RecentGame game) {
  final moments = <GameMoment>[
    ?_bookMoment(game.deviation),
    for (final m in game.summary?.moments ?? const <ReviewMoment>[])
      _mistakeMoment(m),
  ];
  moments.sort((a, b) => a.ply.compareTo(b.ply));
  return moments;
}

GameMoment? _bookMoment(DeviationReport? report) {
  if (report == null || report.inBook) return null;
  final played = report.playedSan!;
  final fen = fenAfterMoves(
    Chess.initial.fen,
    report.pathSans,
    report.pathSans.length - 1,
  );
  final byMe = report.byMe == true;
  final title = formatMoveAtPly(report.matchedPlies, played);
  final String detail;
  final String tooltip;
  if (report.bookEnded) {
    detail = 'Book ends here';
    tooltip =
        'Your prep ends here — ${report.chapterName} has no moves past '
        'this point.\nClick to see the game and the line side by side.';
  } else {
    detail = byMe ? 'You left book' : 'They left book';
    tooltip =
        'Played $played — book plays ${report.expectedSans.join(' / ')}.\n'
        'Click to see the game and your line side by side.';
  }
  return GameMoment(
    ply: report.matchedPlies + 1,
    fen: fen,
    playedUci: sanToUci(fen, played) ?? '',
    wantedUcis: [for (final san in report.expectedSans) ?sanToUci(fen, san)],
    byMe: byMe,
    title: title,
    detail: detail,
    tooltip: tooltip,
    tab: PgnViewerTab.line,
  );
}

GameMoment _mistakeMoment(ReviewMoment m) {
  final label = switch (m.classification) {
    MoveClassification.blunder => 'Blunder',
    MoveClassification.mistake => 'Mistake',
    _ => 'Inaccuracy',
  };
  final glyph = switch (m.classification) {
    MoveClassification.blunder => '??',
    MoveClassification.mistake => '?',
    _ => '?!',
  };
  final eval = m.scoreCp == null && m.scoreMate == null
      ? null
      : formatEvalDisplay(scoreCp: m.scoreCp, scoreMate: m.scoreMate);
  final best = m.bestSan;
  return GameMoment(
    ply: m.ply,
    fen: m.fenBefore,
    playedUci: sanToUci(m.fenBefore, m.san) ?? '',
    wantedUcis: [if (best != null) ?sanToUci(m.fenBefore, best)],
    byMe: true,
    title: '${formatMoveAtPly(m.ply - 1, m.san)}$glyph',
    detail: eval == null ? label : '$label $eval',
    tooltip:
        '$label: ${formatMoveAtPly(m.ply - 1, m.san)}'
        '${eval == null ? '' : ' ($eval after it)'}'
        '${best == null ? '' : ' — engine prefers $best'}.\n'
        'Click to open the analysis at this move.',
    tab: PgnViewerTab.analysis,
    classification: m.classification,
  );
}
