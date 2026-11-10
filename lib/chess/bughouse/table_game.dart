import 'table.dart';

/// What a BPGN's tags say of a game: who sat where, the time each had and
/// how it ended. The moves and their clocks are the line's.
final class TableGame {
  const TableGame(this.tags, {this.ending});

  /// The tags in the order written, without the set-up position, which the
  /// line starts from.
  final Map<String, String> tags;

  /// How the game ended in the file's own words, `LinusO checkmated`: its
  /// closing comment, else its `Termination` tag.
  final String? ending;

  /// Board A of a BPGN is board 1, where A has White and C Black; on board
  /// B, board 2, D has White and B Black.
  static const _seatTag = {
    Seat.a: 'WhiteA',
    Seat.c: 'BlackA',
    Seat.d: 'WhiteB',
    Seat.b: 'BlackB',
  };

  /// Who sat in [seat], when the game names them.
  String? name(Seat seat) => _known(tags[_seatTag[seat]]);

  /// [seat]'s rating as written; FICS gives a guest 0, which is none.
  String? rating(Seat seat) => switch (_known(tags['${_seatTag[seat]}Elo'])) {
    '0' => null,
    final rating => rating,
  };

  /// What every clock started at: the seconds of `TimeControl "120+0"`.
  Duration? get startClock {
    final seconds = RegExp(
      r'^(\d+(?:\.\d+)?)(?:\+\d+(?:\.\d+)?)?$',
    ).firstMatch(tags['TimeControl']?.trim() ?? '')?[1];
    return seconds == null ? null : _seconds(seconds);
  }

  /// The team `Result` gives the game to: `1-0` is board A's White and
  /// partner, A + B.
  Team? get winner => switch (tags['Result']?.trim()) {
    '1-0' => Team.ab,
    '0-1' => Team.cd,
    _ => null,
  };

  /// One line that says which game this is and how it went: `Hivemind Arena
  /// · Round 3 · 2026.11.10 · A + B won · hm-n1500 checkmated`.
  String get heading => [
    ?_known(tags['Event']),
    if (_known(tags['Round']) case final round?) 'Round $round',
    if (_known(tags['Date']) case final date? when !date.contains('?')) date,
    if (winner case final team?)
      '${team.label} won'
    else if (tags['Result']?.trim() == '1/2-1/2')
      'Draw',
    ?ending,
  ].join(' · ');
}

/// A tag's value, or null when it is empty or one of PGN's blanks.
String? _known(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty || text == '?' || text == '-' ? null : text;
}

Duration _seconds(String text) =>
    Duration(milliseconds: (double.parse(text) * 1000).round());

/// A BPGN clock comment as the time left: FICS's `119.000`, seconds, or an
/// older arena file's `1.9s 118.1`, the game's time then the clock. Null
/// for any other comment.
Duration? clockComment(String comment) {
  final seconds = RegExp(
    r'^\s*(?:\d+(?:\.\d+)?s\s+)?(\d+(?:\.\d+)?)\s*$',
  ).firstMatch(comment)?[1];
  return seconds == null ? null : _seconds(seconds);
}

/// [clock] as a chess clock shows it: `1:58`, tenths under ten seconds
/// (`0:07.4`), hours when there are any (`1:02:05`).
String clockText(Duration clock) {
  final tenths = clock.inMilliseconds ~/ 100;
  final seconds = tenths ~/ 10;
  final hours = seconds ~/ 3600;
  final minutes = seconds ~/ 60 % 60;
  final two = (seconds % 60).toString().padLeft(2, '0');
  final text = hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$two'
      : '$minutes:$two';
  return seconds < 10 ? '$text.${tenths % 10}' : text;
}

/// [clock] as BPGN writes it after a move: seconds to the millisecond.
String clockSeconds(Duration clock) =>
    (clock.inMilliseconds / 1000).toStringAsFixed(3);
