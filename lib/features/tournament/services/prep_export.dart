/// Export a tournament prep report as PGN, one chapter per line to study.
///
/// The report is only useful if it reaches a board. This writes a multi-game
/// PGN in the shape the Study screen already imports, so the output of a prep
/// run is something you step through rather than a table you read.
library;

import '../models/player_identity.dart';
import '../models/roster_entry.dart';
import 'tournament_prep_service.dart';

class PrepExporter {
  /// Render [report] as a multi-game PGN.
  ///
  /// Each prep position becomes one game whose mainline is the path into the
  /// gap plus the opponent move we have no answer to, so the board lands
  /// exactly on the position that needs a decision. Who it covers, and how
  /// likely it is, go in the header comment — the reason to study this line
  /// travels with the line.
  static String toPgn(
    TournamentPrepReport report, {
    int? limit,
    double minScore = 0.0,
  }) {
    final selected = report.positions
        .where((p) => p.score >= minScore)
        .take(limit ?? report.positions.length)
        .toList();

    if (selected.isEmpty) {
      return '[Event "${_escape(report.eventName)} — prep"]\n'
          '[Site "Chess Auto Prep"]\n'
          '[Result "*"]\n'
          '[Annotator "Chess Auto Prep"]\n\n'
          '{No prep positions met the threshold.} *\n';
    }

    final buf = StringBuffer();
    for (var i = 0; i < selected.length; i++) {
      buf.write(_gameFor(report, selected[i], i + 1, selected.length));
      buf.write('\n');
    }
    return buf.toString();
  }

  static String _gameFor(
    TournamentPrepReport report,
    PrepPosition position,
    int index,
    int total,
  ) {
    final color = position.weAreWhite ? 'White' : 'Black';
    final event = report.eventName.isEmpty ? 'Tournament' : report.eventName;

    // Chapter title carries the ranking, so the study's chapter list reads as
    // a priority order rather than an unordered pile.
    final title =
        '$index/$total · as $color · ${position.line} — ${position.missingMove}';

    final buf = StringBuffer()
      ..writeln('[Event "${_escape(event)} — prep"]')
      ..writeln('[Site "Chess Auto Prep"]')
      ..writeln('[White "${position.weAreWhite ? 'You' : 'Opponent'}"]')
      ..writeln('[Black "${position.weAreWhite ? 'Opponent' : 'You'}"]')
      ..writeln('[Result "*"]')
      ..writeln('[ChapterName "${_escape(title)}"]')
      ..writeln('[Annotator "Chess Auto Prep"]')
      ..writeln('[PrepScore "${position.score.toStringAsFixed(5)}"]')
      ..writeln('[PrepOpponents "${position.opponentCount}"]')
      ..writeln();

    buf.write('{${_commentFor(position)}} ');
    buf.write(_movetext([...position.movePath, position.missingMove]));
    buf.writeln(' *');

    return buf.toString();
  }

  /// The "why am I looking at this" note attached to the position.
  static String _commentFor(PrepPosition position) {
    final buf = StringBuffer()
      ..write('Your repertoire has no answer to ${position.missingMove} here. ')
      ..write(
        'Expected frequency ${(position.score * 100).toStringAsFixed(2)}% '
        'of your games this event',
      );

    if (position.opponentCount == 1) {
      final o = position.opponents.first;
      buf.write(
        ' — ${o.playerName} '
        '(${(o.pairingProb * 100).toStringAsFixed(0)}% to face, '
        'plays it ${(o.moveShare * 100).toStringAsFixed(0)}% here).',
      );
    } else {
      buf.write(', across ${position.opponentCount} likely opponents: ');
      buf.write(
        position.opponents
            .take(5)
            .map(
              (o) =>
                  '${o.playerName} '
                  '(${(o.pairingProb * 100).toStringAsFixed(0)}%/'
                  '${(o.moveShare * 100).toStringAsFixed(0)}%)',
            )
            .join(', '),
      );
      if (position.opponentCount > 5) {
        buf.write(', +${position.opponentCount - 5} more');
      }
      buf.write('.');
    }

    if (position.transposes) {
      buf.write(
        ' Note: this transposes back into a line you already cover, so it may '
        'be a move-order issue rather than a real hole.',
      );
    }

    return _escapeComment(buf.toString());
  }

  /// SAN list → numbered movetext. The path starts from the initial position,
  /// so White moves sit at even indices.
  static String _movetext(List<String> sans) {
    final buf = StringBuffer();
    for (var i = 0; i < sans.length; i++) {
      if (i.isEven) {
        buf.write('${(i ~/ 2) + 1}. ');
      } else if (i == 0) {
        buf.write('1... ');
      }
      buf.write(sans[i]);
      if (i < sans.length - 1) buf.write(' ');
    }
    return buf.toString();
  }

  /// Per-opponent PGN: every gap for one player, for a focused drill the
  /// night before a known pairing.
  static String opponentPgn(
    TournamentPrepReport report,
    String playerId, {
    int? limit,
  }) {
    final positions = report.positions
        .where((p) => p.opponents.any((o) => o.playerId == playerId))
        .take(limit ?? report.positions.length)
        .toList();

    if (positions.isEmpty) {
      return '[Event "Prep"]\n[Result "*"]\n\n{No gaps found.} *\n';
    }

    final name = positions.first.opponents
        .firstWhere((o) => o.playerId == playerId)
        .playerName;

    final scoped = TournamentPrepReport(
      eventName: '${report.eventName} — $name',
      positions: positions,
      clashReports: report.clashReports
          .where((c) => c.playerId == playerId)
          .toList(),
      simulation: report.simulation,
      elapsed: report.elapsed,
    );
    return toPgn(scoped);
  }

  /// A compact plain-text briefing, for pasting into notes or a chat.
  static String toBriefing(TournamentPrepReport report, {int limit = 10}) {
    final buf = StringBuffer()
      ..writeln('Prep for ${report.eventName}')
      ..writeln('=' * 40);

    final sim = report.simulation;
    if (sim.trials > 0) {
      buf.writeln(
        'Simulated ${sim.trials} runs of a ${sim.rounds}-round Swiss. '
        'Expected score ${sim.expectedScore.toStringAsFixed(1)}/${sim.rounds}.',
      );
    }
    buf.writeln();

    if (report.positions.isEmpty) {
      buf.writeln('No gaps found.');
    } else {
      buf.writeln('Top ${limit} lines to know:');
      for (final (i, p) in report.positions.take(limit).indexed) {
        buf.writeln(
          '${i + 1}. [as ${p.weAreWhite ? 'White' : 'Black'}] '
          '${p.lineWithMove}  '
          '(${(p.score * 100).toStringAsFixed(2)}%, '
          '${p.opponentCount} opponent${p.opponentCount == 1 ? '' : 's'})',
        );
      }
    }

    if (report.warnings.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Notes:');
      for (final w in report.warnings) {
        buf.writeln('  - $w');
      }
    }

    return buf.toString();
  }

  /// The roster as CSV, including resolved accounts — the round-trip format
  /// for handing a field to an agent and getting it back enriched.
  static String rosterToCsv(Roster roster) {
    final buf = StringBuffer()
      ..writeln(
        'Name,USCF ID,Rating,Section,Title,chess.com,lichess,'
        'Confidence,Source,Evidence',
      );

    for (final e in roster.entries) {
      final id = e.identity;
      buf.writeln(
        [
          e.name,
          e.uscfId ?? '',
          e.rating?.toString() ?? '',
          e.section ?? '',
          e.title ?? id?.title ?? '',
          id?.chesscomUsername ?? '',
          id?.lichessUsername ?? '',
          id == null ? '' : id.confidence.wireName,
          id == null ? '' : id.source.wireName,
          id?.evidence ?? '',
        ].map(_csvCell).join(','),
      );
    }
    return buf.toString();
  }

  static String _csvCell(String value) {
    if (!value.contains(',') && !value.contains('"') && !value.contains('\n')) {
      return value;
    }
    return '"${value.replaceAll('"', '""')}"';
  }

  static String _escape(String s) => s.replaceAll('"', "'");

  /// PGN comments are brace-delimited, so braces inside one would truncate it.
  static String _escapeComment(String s) =>
      s.replaceAll('{', '(').replaceAll('}', ')');
}
