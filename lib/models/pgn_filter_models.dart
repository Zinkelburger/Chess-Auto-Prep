/// Serializable filter/slice models for PGN game collections.
///
/// Extracted from `pgn_slice_dialog.dart` so that `core/` and `services/` can
/// depend on these types without importing a widget file.
library;

import 'dart:convert';

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

MatchMode matchModeFromName(String name) => MatchMode.values
    .firstWhere((m) => m.name == name, orElse: () => MatchMode.contains);

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

  Map<String, dynamic> toJson() =>
      {'field': field, 'mode': mode.name, 'value': value};

  factory HeaderFilterConfig.fromJson(Map<String, dynamic> j) =>
      HeaderFilterConfig(
        field: j['field'] as String? ?? 'Black',
        mode: matchModeFromName(j['mode'] as String? ?? 'contains'),
        value: j['value'] as String? ?? '',
      );

  String get chipLabel {
    final modeStr = mode == MatchMode.contains
        ? ''
        : ' (${matchModeLabel(mode, numeric: isNumericField(field))})';
    return '$field$modeStr: $value';
  }
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
        headerFilters: (j['headerFilters'] as List<dynamic>?)
                ?.map((e) =>
                    HeaderFilterConfig.fromJson(e as Map<String, dynamic>))
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

enum GameSortMode {
  fileOrder,
  ratingDesc,
  ratingAsc,
}
