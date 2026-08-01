import '../../../services/games_library/game_filter.dart';
import '../../../services/games_library/games_library_service.dart';
import '../services/game_deviation_service.dart';
import '../services/game_review_summary.dart';

/// How the game ended, from my side of the board.
enum MyGameOutcome { win, loss, draw, unknown }

/// One row of the Games page: a cached [GameRecord] plus the derived display
/// fields and the (lazily computed) repertoire-deviation report.
class RecentGame {
  RecentGame({
    required this.record,
    required this.platform,
    required this.cachePath,
    required this.myUsername,
    required this.meWhite,
    required this.sans,
    this.finalFen,
  });

  final GameRecord record;
  final GamesPlatform platform;

  /// Games-library cache file the PGN viewer opens for this game.
  final String cachePath;

  /// The username whose cache this game came from.
  final String myUsername;

  /// Which side I played; null when neither header matches [myUsername]
  /// (deviation is skipped for such games).
  final bool? meWhite;

  /// Mainline SAN moves (feeds the move count and the deviation walk).
  final List<String> sans;

  /// The position the game ended in, for the row's board preview. Null when
  /// the mainline could not be replayed (a from-position game).
  final String? finalFen;

  /// Filled in after the list loads; null until computed (or when no
  /// repertoire is designated for my color).
  DeviationReport? deviation;
  bool deviationComputed = false;

  /// Whether a repertoire was designated for my color when [deviation] was
  /// computed — distinguishes "nothing designated" from "designated but no
  /// usable chapters" when [deviation] is null.
  bool bookDesignated = false;

  /// Review summary derived from stored `[%eval]` annotations; null when the
  /// game has not been analyzed yet (or my side is unknown). Set during the
  /// list load and again when the background auto-analysis finishes the game.
  GameReviewSummary? summary;

  String get white => record.white;
  String get black => record.black;
  String? get whiteElo => record.headers['WhiteElo'];
  String? get blackElo => record.headers['BlackElo'];
  String get result => record.headers['Result'] ?? '*';

  /// My rating in this game (the Elo header of the side I played), when both
  /// my side and the header are known. Provisional "1500?" style values parse
  /// as their numeric part.
  int? get myElo {
    final mine = meWhite;
    if (mine == null) return null;
    final raw = mine ? whiteElo : blackElo;
    if (raw == null) return null;
    return int.tryParse(raw.replaceAll('?', ''));
  }

  int get moveCount => (sans.length + 1) ~/ 2;

  /// Who I played, or null when neither name is mine.
  String? get opponent => switch (meWhite) {
    true => black,
    false => white,
    null => null,
  };

  /// ECO code, when the platform sent one ("B22").
  String? get ecoCode {
    final eco = record.headers['ECO']?.trim();
    if (eco == null || eco.isEmpty || eco == '?') return null;
    // Chess.com puts the opening *name* in ECO for some exports; a real code
    // is a letter and two digits.
    return RegExp(r'^[A-E]\d\d$').hasMatch(eco) ? eco : null;
  }

  /// Opening name, from Lichess's `Opening` header or Chess.com's `ECOUrl`
  /// slug. Null when neither is present — nothing here is guessed from the
  /// moves, since a wrong opening name is worse than none.
  String? get openingName {
    final named = record.headers['Opening']?.trim();
    if (named != null && named.isNotEmpty && named != '?') return named;
    final url = record.headers['ECOUrl']?.trim();
    if (url == null || url.isEmpty) return null;
    final slug = url.split('/').where((p) => p.isNotEmpty).lastOrNull;
    if (slug == null || slug.isEmpty) return null;
    return slug.replaceAll('-', ' ').trim();
  }

  /// "B22 · Sicilian Defense, Alapin", dropping whichever half is missing.
  String? get openingDisplay {
    final parts = [
      if (ecoCode != null) ecoCode!,
      if (openingName != null) openingName!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The game's opening moves as numbered movetext, for the row's one-line
  /// preview: enough to recognise which of your games this was.
  String movesPreview({int plies = 8}) {
    final shown = sans.take(plies).toList();
    if (shown.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < shown.length; i++) {
      if (i.isEven) buf.write('${i ~/ 2 + 1}. ');
      buf
        ..write(shown[i])
        ..write(' ');
    }
    final text = buf.toString().trimRight();
    return sans.length > shown.length ? '$text …' : text;
  }

  /// The game's web URL (chess.com `Link`, lichess `Site`), when present.
  String? get gameUrl {
    final link = record.headers['Link'] ?? record.headers['Site'];
    if (link != null && link.contains('://')) return link.trim();
    return null;
  }

  /// ("1", "0") style per-player score pair aligned with the White/Black
  /// name rows, like chess.com's list.
  (String, String) get scorePair => switch (result) {
    '1-0' => ('1', '0'),
    '0-1' => ('0', '1'),
    '1/2-1/2' => ('½', '½'),
    _ => ('·', '·'),
  };

  MyGameOutcome get myOutcome {
    final mine = meWhite;
    if (mine == null) return MyGameOutcome.unknown;
    return switch (result) {
      '1-0' => mine ? MyGameOutcome.win : MyGameOutcome.loss,
      '0-1' => mine ? MyGameOutcome.loss : MyGameOutcome.win,
      '1/2-1/2' => MyGameOutcome.draw,
      _ => MyGameOutcome.unknown,
    };
  }

  /// "3+2"-style display of the TimeControl header.
  String get timeControlDisplay =>
      formatTimeControl(record.headers['TimeControl']);

  String get dateDisplay {
    final d = record.date;
    if (d == null) return record.headers['Date'] ?? '—';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  /// Year-less date for the embedded recent-games pane — everything it shows
  /// is inside the expiry window, so the year is noise.
  String get dateDisplayShort {
    final d = record.date;
    if (d == null) return record.headers['Date'] ?? '—';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}

/// "180+2" → "3+2", "600" → "10+0", "30+0" → "½+0", "-" → "∞".
String formatTimeControl(String? tc) {
  if (tc == null || tc.trim().isEmpty) return '?';
  final t = tc.trim();
  if (t == '-') return '∞';
  if (t.contains('/')) return 'corr';
  final parts = t.split('+');
  final base = int.tryParse(parts[0]);
  if (base == null) return t;
  final inc = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final String baseStr;
  if (base % 60 == 0) {
    baseStr = '${base ~/ 60}';
  } else if (base == 30) {
    baseStr = '½';
  } else if (base == 15) {
    baseStr = '¼';
  } else if (base == 45) {
    baseStr = '¾';
  } else {
    baseStr = '${base}s';
  }
  return '$baseStr+$inc';
}
