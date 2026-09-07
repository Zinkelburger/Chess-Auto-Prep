/// A tournament's prep as one readable text file: the field as a table, then
/// each opponent's notes and the lines in their prep file. Markdown, because
/// it reads fine raw and renders anywhere.
library;

import '../models/person_record.dart';
import '../models/tournament.dart';

/// One chapter of a prep file, already flattened to movetext.
class PrepChapterText {
  const PrepChapterText({required this.name, required this.movetext});
  final String name;
  final String movetext;
}

/// One opponent as the export sees them.
class TournamentTextRow {
  const TournamentTextRow({
    required this.person,
    required this.entry,
    this.chapters = const [],
    this.gameCount,
  });

  final PersonRecord person;
  final TournamentEntry entry;
  final List<PrepChapterText> chapters;

  /// Downloaded games on this machine, or null when there is no game-set.
  final int? gameCount;
}

String renderTournamentText(
  Tournament tournament,
  List<TournamentTextRow> rows, {
  DateTime? now,
}) {
  final when = (now ?? DateTime.now()).toIso8601String().substring(0, 10);
  final b = StringBuffer();
  b.writeln('# ${tournament.name}');
  b.writeln();
  final facts = [
    if (tournament.date != null) tournament.date!,
    if (tournament.rounds != null)
      '${tournament.rounds} round${tournament.rounds == 1 ? '' : 's'}',
    '${rows.length} opponent${rows.length == 1 ? '' : 's'}',
    '${tournament.preparedCount} prepared',
  ];
  b.writeln(facts.join(' · '));
  b.writeln();
  b.writeln('Exported $when by Chess Auto Prep.');
  b.writeln();

  b.writeln(
    '| # | Name | Rating | USCF ID | Chess.com | Lichess | Odds | Prepared |',
  );
  b.writeln(
    '|---|------|-------:|---------|-----------|---------|-----:|:--------:|',
  );
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final p = r.person;
    b.writeln(
      '| ${i + 1} '
      '| ${_cell(p.name)} '
      '| ${r.entry.rating ?? p.rating ?? ''} '
      '| ${_cell(p.uscfId ?? '')} '
      '| ${_cell(p.chesscom ?? '')} '
      '| ${_cell(p.lichess ?? '')} '
      '| ${r.entry.pairingProb == null ? '' : '${(r.entry.pairingProb! * 100).round()}%'} '
      '| ${r.entry.prepared ? 'yes' : ''} |',
    );
  }

  for (final r in rows) {
    final p = r.person;
    b.writeln();
    b.writeln('## ${p.name}');
    b.writeln();
    final line = [
      if (p.title != null) p.title!,
      if (r.entry.rating != null || p.rating != null)
        '${r.entry.rating ?? p.rating}',
      if (p.uscfId != null) 'USCF ${p.uscfId}',
      if (p.chesscom != null) 'chess.com ${p.chesscom}',
      if (p.lichess != null) 'lichess ${p.lichess}',
      if (r.entry.likelyRound != null) 'likely round ${r.entry.likelyRound}',
      if (r.entry.pairingProb != null)
        '${(r.entry.pairingProb! * 100).round()}% to face',
      if (r.gameCount != null) '${r.gameCount} games downloaded',
      if (r.entry.prepared) 'prepared',
    ];
    if (line.isNotEmpty) {
      b.writeln(line.join(' · '));
      b.writeln();
    }
    if (p.notes.trim().isNotEmpty) {
      b.writeln(p.notes.trim());
      b.writeln();
    }
    for (final c in r.chapters) {
      b.writeln('### ${c.name}');
      b.writeln();
      b.writeln(
        c.movetext.trim().isEmpty ? '(no moves yet)' : c.movetext.trim(),
      );
      b.writeln();
    }
  }
  return b.toString();
}

String _cell(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');
