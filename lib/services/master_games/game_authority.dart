/// How much authority a database game carries when it is *cited*.
///
/// The TWIC corpus is not what "master games" suggests: over half of it is
/// played on internet servers, and chess.com's weekly 3+1 Titled Tuesday
/// alone is 46% of a five-year import.  Those games are good evidence of what
/// a strong opponent will actually play — that is what the opening book is
/// for — but a repertoire note that says `improves on <game>` is making a
/// claim about theory, and one blitz game is not the same authority as an
/// over-the-board classical one.
///
/// Time control would settle it outright, but TWIC's `TimeControl` header is
/// not stored (and is absent from many issues), so this reads the two headers
/// that are: the site says whether it was played online at all, and the event
/// name carries the speed marker when there is one.
library;

/// Citation tiers, most authoritative first.
enum GameAuthority {
  /// Over the board with no speed marker on the event: the default, and the
  /// only tier a citation prefers.
  classical,

  /// Over the board, but a blitz / rapid / bullet / armageddon event.
  speedOtb,

  /// Played on an internet server.  Titled Tuesday and the rest, and also the
  /// engine events (TCEC, CCC) that ride along in the same issues.
  online;

  /// Whether a citation should reach for this game before falling back.
  bool get isCitable => this == GameAuthority.classical;

  /// Stored as a small int on `games.authority`.
  int get code => index;

  static GameAuthority fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : classical;
}

/// Every online venue in the corpus writes its platform into `Site` and ends
/// it with the `INT` country code — `chess.com INT`, `lichess.org INT`,
/// `FIDE Online Arena INT`, `Tornelo INT`, `tcec-chess.com INT`.  No
/// over-the-board site in five years of TWIC ends that way.
bool _isOnlineSite(String site) {
  final s = site.trimRight();
  return s.length >= 3 && s.toUpperCase().endsWith('INT');
}

/// Speed markers TWIC puts in the event name.
///
/// The event name is all there is: TWIC publishes no `TimeControl` header at
/// all (0 of 10,766 games in issue 1657), and `EventType`, present on 1.7% of
/// games, only ever says `tourn` / `k.o.` / `team-k.o.`.
///
/// `titled tue` is matched by name because chess.com's own event titles
/// ("Titled Tue 16th Dec 2025") carry no other marker and every edition is
/// 3+1 blitz.  `esports` covers the Esports World Cup and the Oslo Esports
/// Cup, both rapid.
///
/// Substring matching earns its false positives, so this list is deliberately
/// short.  Rejected after checking each against the corpus: `kvik` (Kvika is
/// the bank sponsoring the *classical* Reykjavik Open — 1,903 games),
/// `champions` (national and youth championships), `arena` (Satranc Arena, a
/// Turkish over-the-board norm event), and `min` (Minsk, Mindsports,
/// Bohumin).
const _speedMarkers = [
  'blitz',
  'rapid',
  'bullet',
  'armageddon',
  'titled tue',
  'esports',
];

bool _isSpeedEvent(String event) {
  final e = event.toLowerCase();
  for (final marker in _speedMarkers) {
    if (e.contains(marker)) return true;
  }
  return false;
}

/// Classify a game from the two headers the database keeps.
GameAuthority classifyAuthority({required String site, required String event}) {
  if (_isOnlineSite(site)) return GameAuthority.online;
  if (_isSpeedEvent(event)) return GameAuthority.speedOtb;
  return GameAuthority.classical;
}

/// The same rule as SQL, for backfilling an already-imported database without
/// re-reading a single game.  Returns a `CASE` expression over `site`/`event`
/// yielding [GameAuthority.code].
const String kAuthoritySqlExpression = '''
CASE
  WHEN upper(rtrim(site)) LIKE '%INT' THEN 2
  WHEN lower(event) LIKE '%blitz%' OR lower(event) LIKE '%rapid%'
    OR lower(event) LIKE '%bullet%' OR lower(event) LIKE '%armageddon%'
    OR lower(event) LIKE '%titled tue%' OR lower(event) LIKE '%esports%'
    THEN 1
  ELSE 0
END''';
