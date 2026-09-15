/// Serializable filter/slice models for PGN game collections.
///
/// Shared by collection search, inline import filters and their services.
library;

import 'dart:convert';

// ── Player names ─────────────────────────────────────────────────────────────

/// Pseudo header field that matches a player on **either** colour, with
/// multi-name support (see [splitPlayerNames]). Not a real PGN header, so
/// filter code must special-case it instead of doing a `headers[field]`
/// lookup.
const kPlayerHeaderField = 'Player';

/// Split a player-name input into individual names to match.
///
/// Separator is `;` — commas appear inside PGN names ("Carlsen, Magnus"),
/// so they cannot delimit. Parts are trimmed; empties dropped.
List<String> splitPlayerNames(String input) =>
    input.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

// ── Match mode ───────────────────────────────────────────────────────────────

/// How a header filter's value is compared with the header.
enum MatchMode {
  contains,
  notContains,
  exact,
  regex,

  /// `≥`: on or after a date, at least a number.
  after,

  /// `≤`: on or before a date, at most a number.
  before;

  /// The mode persisted under [name], or [contains] for anything unknown.
  static MatchMode fromName(String name) =>
      values.asNameMap()[name] ?? MatchMode.contains;
}

/// Fields where ≥/≤ represent numeric comparison, not temporal.
bool isNumericField(String field) =>
    field == 'WhiteElo' || field == 'BlackElo' || field == 'StudyRating';

// ── Header filter ────────────────────────────────────────────────────────────

/// A single header-based filter criterion.
class HeaderFilterConfig {
  final String field;
  final MatchMode mode;
  final String value;

  const HeaderFilterConfig({
    required this.field,
    required this.mode,
    required this.value,
  });

  Map<String, dynamic> toJson() => {
    'field': field,
    'mode': mode.name,
    'value': value,
  };

  factory HeaderFilterConfig.fromJson(Map<String, dynamic> j) =>
      HeaderFilterConfig(
        field: j['field'] as String? ?? 'Black',
        mode: MatchMode.fromName(j['mode'] as String? ?? 'contains'),
        value: j['value'] as String? ?? '',
      );

  /// Readable condition prefix, shared by the editor and active chips.
  /// Bounds remain inclusive, just as in the persisted matching modes.
  String get conditionLabel {
    if (field == 'Date') {
      if (mode == MatchMode.after) return 'After';
      if (mode == MatchMode.before) return 'Before';
    }
    final subject = switch (field) {
      'WhiteElo' => 'White rating',
      'BlackElo' => 'Black rating',
      'StudyRating' => 'Study rating',
      'StudySummary' => 'Study summary',
      'White' => 'White name',
      'Black' => 'Black name',
      kPlayerHeaderField => 'Player name',
      _ => field,
    };
    final relation = switch (mode) {
      MatchMode.contains => 'contains',
      MatchMode.notContains => 'excludes',
      MatchMode.exact => 'is',
      MatchMode.regex => 'matches regex',
      MatchMode.after => 'at least',
      MatchMode.before => 'at most',
    };
    return '$subject $relation';
  }

  String get chipLabel => '$conditionLabel $value';
}

// ── Slice config ─────────────────────────────────────────────────────────────

/// Serializable snapshot of all slice filters.
class SliceConfig {
  final String? positionInput;
  final List<String> additionalPositions;
  final bool matchAny;
  final List<HeaderFilterConfig> headerFilters;
  final String? sequencePattern;
  final int sequenceGap;

  const SliceConfig({
    this.positionInput,
    this.additionalPositions = const [],
    this.matchAny = false,
    this.headerFilters = const [],
    this.sequencePattern,
    this.sequenceGap = defaultSequenceGap,
  });
  const SliceConfig.empty()
    : positionInput = null,
      additionalPositions = const [],
      matchAny = false,
      headerFilters = const [],
      sequencePattern = null,
      sequenceGap = defaultSequenceGap;

  /// Gap between pattern moves when the caller does not say.
  static const int defaultSequenceGap = 4;

  bool get isEmpty =>
      (positionInput?.trim().isEmpty ?? true) &&
      additionalPositions.every((p) => p.trim().isEmpty) &&
      headerFilters.every((f) => f.value.isEmpty) &&
      (sequencePattern?.trim().isEmpty ?? true);

  String toJsonString() => jsonEncode({
    if (positionInput case final position? when position.isNotEmpty)
      'positionInput': position,
    if (additionalPositions.isNotEmpty)
      'additionalPositions': additionalPositions,
    if (matchAny) 'matchAny': true,
    'headerFilters': headerFilters.map((f) => f.toJson()).toList(),
    if (sequencePattern case final pattern? when pattern.isNotEmpty)
      'sequencePattern': pattern,
    if (sequenceGap != defaultSequenceGap) 'sequenceGap': sequenceGap,
  });

  factory SliceConfig.fromJsonString(String s) {
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return SliceConfig(
        positionInput: j['positionInput'] as String?,
        additionalPositions:
            (j['additionalPositions'] as List<dynamic>?)?.cast<String>() ??
            const [],
        matchAny: j['matchAny'] as bool? ?? false,
        headerFilters:
            (j['headerFilters'] as List<dynamic>?)
                ?.map(
                  (e) => HeaderFilterConfig.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        sequencePattern: j['sequencePattern'] as String?,
        sequenceGap: (j['sequenceGap'] as int?) ?? defaultSequenceGap,
      );
    } on FormatException {
      // Not JSON: a slice saved by a version this one cannot read is no
      // slice at all, not a crash on opening the source list.
      return const SliceConfig.empty();
    } on TypeError {
      // JSON of the wrong shape, same answer.
      return const SliceConfig.empty();
    }
  }

  List<String> get chipLabels => [
    if (positionInput case final position? when position.isNotEmpty)
      'Pos: ${_truncate(position, 20)}',
    for (final position in additionalPositions)
      if (position.isNotEmpty) 'Pos: ${_truncate(position, 20)}',
    if (sequencePattern case final pattern? when pattern.isNotEmpty)
      'Seq: ${_truncate(pattern, 18)} (gap $sequenceGap)',
    for (final f in headerFilters)
      if (f.value.isNotEmpty) f.chipLabel,
  ];

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

// ── Game record ──────────────────────────────────────────────────────────────

typedef GameRecord = ({Map<String, String> headers, String pgnText});

// ── Sort mode ────────────────────────────────────────────────────────────────

/// How the game list is ordered.
///
/// [dateDesc] exists because "file order" is meaningless for the games cache:
/// it is a merge log (new downloads append, and the two sites' fetchers hand
/// back their own orders), so the game you just played can land anywhere in it
/// — "Game 301 / 312" for the most recent game is not a bug, it is file order
/// being the wrong question. Anything opened from the recent-games list starts
/// newest-first instead, which is the order that list itself is in.
enum GameSortMode { fileOrder, dateDesc, ratingDesc, ratingAsc }
