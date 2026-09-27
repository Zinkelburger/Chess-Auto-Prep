/// Filtering a game collection: header matching, move-sequence patterns,
/// position targets and the combined slice computation that the collection
/// search, the inline import filter and the Viewer filter owner share.
///
/// The predicates and candidate matching are pure Dart. Scheduling lives in the
/// injected collection-filter adapter.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/pgn_filter_models.dart';
import '../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../utils/fen_utils.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart';

// ── Field matching ───────────────────────────────────────────────────────────

/// Checks whether [headerVal] satisfies [query] under the given [mode].
///
/// Used by both the slice dialog and the controller to filter games by header
/// values.
bool matchesField(String headerVal, String query, MatchMode mode) {
  switch (mode) {
    case MatchMode.contains:
      return headerVal.toLowerCase().contains(query.toLowerCase());
    case MatchMode.notContains:
      return !headerVal.toLowerCase().contains(query.toLowerCase());
    case MatchMode.exact:
      return headerVal.toLowerCase() == query.toLowerCase();
    case MatchMode.regex:
      return _tryRegExp(query)?.hasMatch(headerVal) ?? false;
    case MatchMode.after:
      return _orderedMatch(headerVal, query, atLeast: true);
    case MatchMode.before:
      return _orderedMatch(headerVal, query, atLeast: false);
  }
}

/// Numeric fields (WhiteElo/BlackElo/StudyRating) must compare numerically,
/// not lexicographically — otherwise "≥ 500" wrongly excludes a 2400 game
/// ("2400" < "500"). Dates ("YYYY.MM.DD") don't parse as num, so they fall
/// back to the correct string compare.
bool _orderedMatch(String headerVal, String query, {required bool atLeast}) {
  final hv = num.tryParse(headerVal);
  final q = num.tryParse(query);
  if (hv != null && q != null) return atLeast ? hv >= q : hv <= q;
  final order = headerVal.compareTo(query);
  return atLeast ? order >= 0 : order <= 0;
}

RegExp? _tryRegExp(String pattern) {
  try {
    return RegExp(pattern, caseSensitive: false);
  } on FormatException {
    return null;
  }
}

/// [kPlayerHeaderField] filter: does either colour's header satisfy [query]?
///
/// [query] may hold several `;`-separated names ([splitPlayerNames]); a game
/// passes when **any** name matches **either** side — except in
/// [MatchMode.notContains], where **every** name must be absent from **both**
/// sides (the natural reading of "player not contains X").
bool playerFieldMatches(
  String whiteHeader,
  String blackHeader,
  String query,
  MatchMode mode,
) {
  final names = splitPlayerNames(query);
  if (names.isEmpty) return true;
  if (mode == MatchMode.notContains) {
    return names.every(
      (n) =>
          matchesField(whiteHeader, n, mode) &&
          matchesField(blackHeader, n, mode),
    );
  }
  return names.any(
    (n) =>
        matchesField(whiteHeader, n, mode) ||
        matchesField(blackHeader, n, mode),
  );
}

/// A header filter with its mode resolved and its query lower-cased once,
/// rather than per game.  [MatchMode.regex] compiles its pattern once too.
class _CompiledFilter {
  _CompiledFilter(this.field, this.mode, this.value)
    : queryLower = value.toLowerCase(),
      regex = mode == MatchMode.regex ? _tryRegExp(value) : null;

  final String field;
  final MatchMode mode;
  final String value;
  final String queryLower;
  final RegExp? regex;

  static List<_CompiledFilter> compileAll(
    List<({String field, String modeName, String value})> filters,
  ) => [
    for (final f in filters)
      if (f.value.isNotEmpty)
        _CompiledFilter(f.field, MatchMode.fromName(f.modeName), f.value),
  ];

  bool matches(Map<String, String> headers) {
    if (field == kPlayerHeaderField) {
      return playerFieldMatches(
        headers['White'] ?? '',
        headers['Black'] ?? '',
        value,
        mode,
      );
    }
    final headerVal = headers[field] ?? '';
    switch (mode) {
      case MatchMode.contains:
        return headerVal.toLowerCase().contains(queryLower);
      case MatchMode.notContains:
        return !headerVal.toLowerCase().contains(queryLower);
      case MatchMode.exact:
        return headerVal.toLowerCase() == queryLower;
      case MatchMode.regex:
        return regex?.hasMatch(headerVal) ?? false;
      case MatchMode.after:
      case MatchMode.before:
        return matchesField(headerVal, value, mode);
    }
  }
}

// ── Sequence matching ────────────────────────────────────────────────────────

final RegExp _gapTokenRe = RegExp(r'\[gap\]', caseSensitive: false);
final RegExp _moveNumberRe = RegExp(r'\d+\.+');
final RegExp _resultTokenRe = RegExp(r'(1-0|0-1|1/2-1/2|\*)');
final RegExp _whitespaceRe = RegExp(r'\s+');

/// The SAN tokens of loosely typed movetext: move numbers and results
/// dropped, whitespace-separated.
List<String> _sanTokens(String text) => text
    .replaceAll(_moveNumberRe, '')
    .replaceAll(_resultTokenRe, '')
    .split(_whitespaceRe)
    .where((t) => t.isNotEmpty)
    .toList();

/// Parse a sequence pattern string into groups of consecutive SAN moves.
///
/// Groups are separated by `[gap]` tokens.
/// Example: "d5 e5 [gap] f6" -> [["d5","e5"], ["f6"]]
List<List<String>> parseSequenceGroups(String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.isEmpty) return const [];
  return [
    for (final part in trimmed.split(_gapTokenRe))
      if (_sanTokens(part) case final tokens when tokens.isNotEmpty) tokens,
  ];
}

/// Whether [moves] contain every group of [groups] in order, each group as
/// consecutive moves, with at most [maxGap] plies between the end of one
/// group and the start of the next. The first group may start anywhere.
bool movesMatchSequence(
  List<String> moves,
  List<List<String>> groups,
  int maxGap,
) => _matchGroupsAt(moves, groups, 0, 0, maxGap);

bool _matchGroupsAt(
  List<String> moves,
  List<List<String>> groups,
  int gi,
  int mi,
  int maxGap,
) {
  if (gi >= groups.length) return true;
  final group = groups[gi];
  if (group.length > moves.length) return false;
  final searchLimit = gi == 0 ? moves.length : mi + maxGap;
  final end = searchLimit.clamp(0, moves.length - group.length);
  for (var i = mi; i <= end; i++) {
    var ok = true;
    for (var j = 0; j < group.length; j++) {
      if (moves[i + j] != group[j]) {
        ok = false;
        break;
      }
    }
    if (ok && _matchGroupsAt(moves, groups, gi + 1, i + group.length, maxGap)) {
      return true;
    }
  }
  return false;
}

/// Check whether a game's mainline matches the sequence groups with the
/// given max gap (in ply) between groups.
bool gameMatchesSequence(
  String pgnText,
  List<List<String>> groups,
  int maxGap,
) {
  if (groups.isEmpty) return true;
  final replay = PgnReplayGame.tryParse(const {}, pgnText);
  return replay != null &&
      movesMatchSequence(replay.mainlineSans, groups, maxGap);
}

// ── Position input parsing ───────────────────────────────────────────────────

/// Parse a position input string (FEN or SAN sequence) into a normalized
/// 4-field target FEN.  Returns `null` on empty/invalid input.
String? parseTargetFen(String? input) {
  if (input == null || input.isEmpty) return null;
  final trimmed = input.trim();
  if (trimmed.contains('/')) {
    try {
      final full = expandFen(trimmed);
      Chess.fromSetup(Setup.parseFen(full));
      return normalizeFen(full);
    } catch (_) {
      // Not a FEN this position model accepts: no target.
      return null;
    }
  }
  final tokens = _sanTokens(trimmed);
  if (tokens.isEmpty) return null;
  try {
    Position pos = Chess.initial;
    for (final t in tokens) {
      final next = playSanOrNullMove(pos, t);
      if (next == null) return null;
      pos = next;
    }
    return normalizeFen(pos.fen);
  } catch (_) {
    // dartchess' parseSan/play can throw (e.g. RangeError) on some malformed
    // tokens — a stray '(' from pasted variation movetext, an 'x'-prefixed
    // token — rather than returning null. Treat any such input as "no target",
    // matching the FEN branch above and this function's documented contract.
    return null;
  }
}

// ── Shared slice compute ─────────────────────────────────────────────────────

/// Match a prepared set of candidates; callers own scheduling and input capture.
List<int> matchPgnSliceCandidates({
  required List<({int index, Map<String, String> headers, String pgnText})>
  gameData,
  required List<({String field, String modeName, String value})> filterData,
  required List<String> targets,
  required List<Set<int>>? positionSets,
  required List<List<String>> seqCopy,
  required int seqGap,
  required bool matchAny,
}) {
  final compiled = _CompiledFilter.compileAll(filterData);
  final noConditions = compiled.isEmpty && targets.isEmpty && seqCopy.isEmpty;
  return [
    for (final game in gameData)
      if (noConditions ||
          _gameMatches(
            game,
            compiled: compiled,
            targets: targets,
            positionSets: positionSets,
            seqGroups: seqCopy,
            seqGap: seqGap,
            matchAny: matchAny,
          ))
        game.index,
  ];
}

/// Whether one game satisfies the slice: every condition, or any when
/// [matchAny]. The game is parsed at most once, and only when a replay-based
/// condition is actually reached.
bool _gameMatches(
  ({int index, Map<String, String> headers, String pgnText}) game, {
  required List<_CompiledFilter> compiled,
  required List<String> targets,
  required List<Set<int>>? positionSets,
  required List<List<String>> seqGroups,
  required int seqGap,
  required bool matchAny,
}) {
  PgnReplayGame? replay;
  var parsed = false;
  PgnReplayGame? readReplay() {
    if (!parsed) {
      replay = PgnReplayGame.tryParse(game.headers, game.pgnText);
      parsed = true;
    }
    return replay;
  }

  Iterable<bool> conditions() sync* {
    for (final filter in compiled) {
      yield filter.matches(game.headers);
    }
    for (var j = 0; j < targets.length; j++) {
      yield positionSets != null
          ? positionSets[j].contains(game.index)
          : readReplay()?.passesThroughFen(targets[j]) ?? false;
    }
    if (seqGroups.isNotEmpty) {
      final moves = readReplay()?.mainlineSans;
      yield moves != null && movesMatchSequence(moves, seqGroups, seqGap);
    }
  }

  return matchAny
      ? conditions().any((value) => value)
      : conditions().every((value) => value);
}
