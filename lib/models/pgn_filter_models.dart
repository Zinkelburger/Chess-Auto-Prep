/// Serializable filter/slice models for PGN game collections.
///
/// Extracted from `pgn_slice_dialog.dart` so that `core/` and `services/` can
/// depend on these types without importing a widget file.
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

enum MatchMode { contains, notContains, exact, regex, after, before }

String matchModeLabel(MatchMode m, {bool numeric = false}) => switch (m) {
  MatchMode.contains => 'contains',
  MatchMode.notContains => 'not contains',
  MatchMode.exact => 'exact',
  MatchMode.regex => 'regex',
  MatchMode.after => numeric ? '≥ (min)' : '≥ (after)',
  MatchMode.before => numeric ? '≤ (max)' : '≤ (before)',
};

MatchMode matchModeFromName(String name) => MatchMode.values.firstWhere(
  (m) => m.name == name,
  orElse: () => MatchMode.contains,
);

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
        mode: matchModeFromName(j['mode'] as String? ?? 'contains'),
        value: j['value'] as String? ?? '',
      );

  /// Readable condition prefix, shared by the editor and active chips.
  /// Bounds remain inclusive, just as in the persisted matching modes.
  String get conditionLabel {
    if (field == 'Date') {
      if (mode == MatchMode.after) return 'In or after';
      if (mode == MatchMode.before) return 'In or before';
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
  final List<HeaderFilterConfig> headerFilters;
  final String? sequencePattern;
  final int sequenceGap;

  const SliceConfig({
    this.positionInput,
    this.headerFilters = const [],
    this.sequencePattern,
    this.sequenceGap = 4,
  });
  const SliceConfig.empty()
    : positionInput = null,
      headerFilters = const [],
      sequencePattern = null,
      sequenceGap = 4;

  bool get isEmpty =>
      (positionInput == null || positionInput!.trim().isEmpty) &&
      headerFilters.every((f) => f.value.isEmpty) &&
      (sequencePattern == null || sequencePattern!.trim().isEmpty);

  String toJsonString() => jsonEncode({
    if (positionInput != null && positionInput!.isNotEmpty)
      'positionInput': positionInput,
    'headerFilters': headerFilters.map((f) => f.toJson()).toList(),
    if (sequencePattern != null && sequencePattern!.isNotEmpty)
      'sequencePattern': sequencePattern,
    if (sequenceGap != 4) 'sequenceGap': sequenceGap,
  });

  factory SliceConfig.fromJsonString(String s) {
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return SliceConfig(
        positionInput: j['positionInput'] as String?,
        headerFilters:
            (j['headerFilters'] as List<dynamic>?)
                ?.map(
                  (e) => HeaderFilterConfig.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
        sequencePattern: j['sequencePattern'] as String?,
        sequenceGap: (j['sequenceGap'] as int?) ?? 4,
      );
    } catch (_) {
      return const SliceConfig.empty();
    }
  }

  List<String> get chipLabels => [
    if (positionInput != null && positionInput!.isNotEmpty)
      'Pos: ${_truncate(positionInput!, 20)}',
    if (sequencePattern != null && sequencePattern!.isNotEmpty)
      'Seq: ${_truncate(sequencePattern!, 18)} (gap $sequenceGap)',
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
