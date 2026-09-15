/// A tournament's prep as one readable text file: the field as a table, then
/// each opponent's notes and the lines in their prep file. Markdown, because
/// it reads fine raw and renders anywhere.
///
/// The output is what the user keeps after the event; its shape is pinned
/// by `test/features/opponents/tournament_text_export_test.dart`.
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

  /// The rating for this event, falling back to the directory's.
  int? get rating => entry.rating ?? person.rating;
}

const _tableHeader =
    '| # | Name | Rating | USCF ID | Chess.com | Lichess | Odds | Prepared |\n'
    '|---|------|-------:|---------|-----------|---------|-----:|:--------:|';

String renderTournamentText(
  Tournament tournament,
  List<TournamentTextRow> rows, {
  DateTime? now,
}) {
  final when = (now ?? DateTime.now()).toIso8601String().substring(0, 10);
  final b = StringBuffer();
  b.writeln('# ${tournament.name}');
  b.writeln();
  b.writeln(_factsLine(tournament, rows.length));
  b.writeln();
  b.writeln('Exported $when by Chess Auto Prep.');
  b.writeln();
  b.writeln(_tableHeader);
  for (final (i, row) in rows.indexed) {
    b.writeln(_tableRow(i + 1, row));
  }
  for (final row in rows) {
    b.writeln();
    _writeSection(b, row);
  }
  return b.toString();
}

String _factsLine(Tournament tournament, int opponents) => [
  ?tournament.date,
  if (tournament.rounds case final rounds?) _plural(rounds, 'round'),
  _plural(opponents, 'opponent'),
  '${tournament.preparedCount} prepared',
].join(' · ');

String _tableRow(int number, TournamentTextRow row) {
  final person = row.person;
  final entry = row.entry;
  return '| $number '
      '| ${_cell(person.name)} '
      '| ${row.rating ?? ''} '
      '| ${_cell(person.uscfId ?? '')} '
      '| ${_cell(person.chesscom ?? '')} '
      '| ${_cell(person.lichess ?? '')} '
      '| ${entry.pairingProb == null ? '' : _percent(entry.pairingProb!)} '
      '| ${entry.prepared ? 'yes' : ''} |';
}

void _writeSection(StringBuffer b, TournamentTextRow row) {
  final person = row.person;
  final entry = row.entry;
  b.writeln('## ${person.name}');
  b.writeln();
  final facts = [
    ?person.title,
    if (row.rating case final rating?) '$rating',
    if (person.uscfId != null) 'USCF ${person.uscfId}',
    if (person.chesscom != null) 'chess.com ${person.chesscom}',
    if (person.lichess != null) 'lichess ${person.lichess}',
    if (entry.likelyRound != null) 'likely round ${entry.likelyRound}',
    if (entry.pairingProb case final prob?) '${_percent(prob)} to face',
    if (row.gameCount != null) '${row.gameCount} games downloaded',
    if (entry.prepared) 'prepared',
  ];
  if (facts.isNotEmpty) {
    b.writeln(facts.join(' · '));
    b.writeln();
  }
  final notes = person.notes.trim();
  if (notes.isNotEmpty) {
    b.writeln(notes);
    b.writeln();
  }
  for (final chapter in row.chapters) {
    final movetext = chapter.movetext.trim();
    b.writeln('### ${chapter.name}');
    b.writeln();
    b.writeln(movetext.isEmpty ? '(no moves yet)' : movetext);
    b.writeln();
  }
}

String _plural(int count, String noun) =>
    '$count $noun${count == 1 ? '' : 's'}';

String _percent(double fraction) => '${(fraction * 100).round()}%';

/// A table cell: pipes escaped, line breaks flattened.
String _cell(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');
