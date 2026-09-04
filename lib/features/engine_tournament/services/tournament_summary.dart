/// One-line readings of a saved tournament, for the history rail.
///
/// The rail's job is to answer "what happened in that match?" without opening
/// it, so the arithmetic is the crosstable's — [buildCrosstable] — rather than
/// a second, quietly different tally. Pure functions over stored data, which
/// is what lets the tests pin the wording down.
library;

import '../models/stored_tournament.dart';
import '../models/tournament_config.dart';
import '../../../services/crosstable_builder.dart';

/// `5½`, `5`, `½` — the way a match score is always written.
String formatMatchPoints(double points) {
  final whole = points.floor();
  final hasHalf = (points - whole).abs() > 0.001;
  if (!hasHalf) return '$whole';
  return whole == 0 ? '½' : '$whole½';
}

/// Engine names for display, with `#1`/`#2` appended to any that repeat.
///
/// An engine playing itself — the standard way to sanity-check a change
/// against its own baseline — otherwise reads as "Stockfish beat Stockfish".
List<String> engineDisplayNames(TournamentConfig config) {
  final counts = <String, int>{};
  for (final engine in config.engines) {
    counts[engine.name] = (counts[engine.name] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return [
    for (final engine in config.engines)
      if ((counts[engine.name] ?? 0) < 2)
        engine.name
      else
        '${engine.name} #${seen[engine.name] = (seen[engine.name] ?? 0) + 1}',
  ];
}

/// How a tournament stands, in one line.
class TournamentOutcome {
  const TournamentOutcome({required this.label, this.leader});

  /// `Alpha 5½–4½ Beta` for a match, `Alpha leads on 7/12` for a field.
  final String label;

  /// Who is ahead, or null when nobody is — an even match, or no games yet.
  final String? leader;

  bool get isDecided => leader != null;
}

/// The score line for [tournament], or null when it has played nothing.
///
/// Two engines get the match score both ways round, in seeding order, because
/// that is the order everything else about the match is written in. A larger
/// field gets its leader, since a rail row has no space for standings.
TournamentOutcome? tournamentOutcome(StoredTournament tournament) {
  final config = tournament.config;
  if (tournament.games.isEmpty || config.engines.isEmpty) return null;
  final table = buildCrosstable([
    for (final e in config.engines) e.name,
  ], tournament.games);
  if (table.isEmpty) return null;

  final names = engineDisplayNames(config);
  final byIndex = {for (final row in table.standings) row.engineIndex: row};
  final running = tournament.status == TournamentStatus.running;

  if (config.engines.length == 2) {
    final a = byIndex[0], b = byIndex[1];
    if (a == null || b == null) return null;
    final score =
        '${formatMatchPoints(a.points)}–${formatMatchPoints(b.points)}';
    final leader = a.points == b.points
        ? null
        : (a.points > b.points ? names[0] : names[1]);
    return TournamentOutcome(
      label: '${names[0]} $score ${names[1]}',
      leader: leader,
    );
  }

  final top = table.standings.first;
  final tied = table.standings
      .where((row) => row.points == top.points)
      .toList();
  final score = '${formatMatchPoints(top.points)}/${top.played}';
  if (tied.length > 1) {
    final who = tied.map((row) => names[row.engineIndex]).join(', ');
    return TournamentOutcome(label: '$who tied on $score');
  }
  final verb = running ? 'leads on' : 'won with';
  return TournamentOutcome(
    label: '${names[top.engineIndex]} $verb $score',
    leader: names[top.engineIndex],
  );
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Heading a run belongs under in the history rail: `Today`, `Yesterday`, or
/// the month it happened in.
///
/// [now] is a parameter so the tests do not have to run at a particular hour.
String tournamentDayGroup(DateTime when, {DateTime? now}) {
  final today = _midnight(now ?? DateTime.now());
  final day = _midnight(when);
  final daysAgo = today.difference(day).inDays;
  if (daysAgo == 0) return 'Today';
  if (daysAgo == 1) return 'Yesterday';
  return '${_monthNames[when.month - 1]} ${when.year}';
}

/// When a run started, as short as it can be without losing what matters:
/// the clock time for something from the last day or two, the date otherwise.
String tournamentTimeLabel(DateTime when, {DateTime? now}) {
  final today = _midnight(now ?? DateTime.now());
  final daysAgo = today.difference(_midnight(when)).inDays;
  final clock =
      '${when.hour.toString().padLeft(2, '0')}:'
      '${when.minute.toString().padLeft(2, '0')}';
  if (daysAgo <= 1) return clock;
  return '${_monthNames[when.month - 1].substring(0, 3)} ${when.day}';
}

DateTime _midnight(DateTime when) => DateTime(when.year, when.month, when.day);
