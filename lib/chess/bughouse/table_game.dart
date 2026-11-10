import 'table.dart';

/// What a BPGN's tags say of a game: who sat where, the time each had and
/// how it ended. The moves and their clocks are the line's.
final class TableGame {
  const TableGame(this.tags, {this.ending});

  /// The tags in the order written, without the set-up position, which the
  /// line starts from.
  final Map<String, String> tags;

  /// How the game ended in the file's own words: its `Termination` tag
  /// (`checkmate`), else its closing comment (`LinusO checkmated`).
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
    final seconds = _timeControl.firstMatch(
      tags['TimeControl']?.trim() ?? '',
    )?[1];
    return seconds == null ? null : _seconds(seconds);
  }

  /// The game's tags for a line that is no longer the one it played: no
  /// result and no ending, since that line did not reach them.
  TableGame get unfinished => TableGame({
    for (final MapEntry(:key, :value) in tags.entries)
      if (key != 'Termination') key: key == 'Result' ? '*' : value,
  });

  /// The team `Result` gives the game to: `1-0` is board A's White and
  /// partner, A + B.
  Team? get winner => switch (tags['Result']?.trim()) {
    '1-0' => Team.ab,
    '0-1' => Team.cd,
    _ => null,
  };

  /// One line that says how the game went and which it is, the result
  /// first since the line is cut short where the room ends: `A + B won ·
  /// checkmate · Hivemind Arena · Round 3 · 2026.11.10`.
  String get heading => [
    if (winner case final team?)
      '${team.label} won'
    else if (tags['Result']?.trim() == '1/2-1/2')
      'Draw',
    ?ending,
    ?_known(tags['Event']),
    if (_known(tags['Round']) case final round?) 'Round $round',
    if (_known(tags['Date']) case final date? when !date.contains('?')) date,
  ].join(' · ');
}

/// A tag's value, or null when it is empty or one of PGN's blanks.
String? _known(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty || text == '?' || text == '-' ? null : text;
}

Duration _seconds(String text) =>
    Duration(milliseconds: (double.parse(text) * 1000).round());

/// The clock in the comment after a BPGN move, as the time left: FICS's
/// `119.000`, seconds; the arena's `[%clk 0:01:58.1]` among its other
/// notes; or an older arena file's `1.9s 118.1`, the game's time then the
/// clock. Null for a comment without one.
Duration? clockComment(String comment) {
  if (_clk.firstMatch(comment) case final clk?) {
    return Duration(hours: int.parse(clk[1]!), minutes: int.parse(clk[2]!)) +
        _seconds(clk[3]!);
  }
  final seconds = _bareClock.firstMatch(comment)?[1];
  return seconds == null ? null : _seconds(seconds);
}

final _timeControl = RegExp(r'^(\d+(?:\.\d+)?)(?:\+\d+(?:\.\d+)?)?$');
final _clk = RegExp(r'\[%clk\s+(\d+):(\d+):(\d+(?:\.\d+)?)\]');
final _bareClock = RegExp(r'^\s*(?:\d+(?:\.\d+)?s\s+)?(\d+(?:\.\d+)?)\s*$');

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
