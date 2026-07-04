/// Shared state for the PGN slice filters (position, sequence, headers).
///
/// Owned by the dialog/editor hosting the filter widgets. The widgets under
/// `widgets/slice/` render from this controller and mutate it, so hosts read
/// filter values directly instead of reaching into child widget State via
/// GlobalKeys.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';

import '../models/pgn_filter_models.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../utils/fen_utils.dart';

// ── Position parsing ─────────────────────────────────────────────────────────

/// Result of attempting to parse a position input string.
class PositionParseResult {
  final String? fen;
  final String? error;
  const PositionParseResult.ok(this.fen) : error = null;
  const PositionParseResult.err(this.error) : fen = null;
  bool get isValid => fen != null;
}

/// Try to interpret [input] as either a FEN or a SAN move sequence.
PositionParseResult parsePositionInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const PositionParseResult.ok(null);

  if (trimmed.contains('/')) {
    try {
      final fullFen = expandFen(trimmed);
      Chess.fromSetup(Setup.parseFen(fullFen));
      return PositionParseResult.ok(normalizeFen(fullFen));
    } catch (e) {
      return PositionParseResult.err('Invalid FEN: $e');
    }
  }

  return _parseSanSequence(trimmed);
}

PositionParseResult _parseSanSequence(String input) {
  final tokens = input
      .replaceAll(RegExp(r'\d+\.+'), '')
      .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  if (tokens.isEmpty) {
    return const PositionParseResult.err('No moves found');
  }

  Position pos = Chess.initial;
  for (int i = 0; i < tokens.length; i++) {
    try {
      final move = pos.parseSan(tokens[i]);
      if (move == null) {
        return PositionParseResult.err(
            "Could not parse move ${i + 1}: '${tokens[i]}'");
      }
      pos = pos.play(move);
    } catch (e) {
      return PositionParseResult.err("Invalid move ${i + 1}: '${tokens[i]}'");
    }
  }
  return PositionParseResult.ok(normalizeFen(pos.fen));
}

// ── Header filter rows ───────────────────────────────────────────────────────

/// Available PGN header field options.
const kHeaderFieldOptions = [
  'White',
  'Black',
  'Event',
  'Result',
  'Date',
  'ECO',
  'Opening',
  'Site',
  'WhiteElo',
  'BlackElo',
  'StudyRating',
  'StudySummary',
];

/// Match modes available for a given field.
List<MatchMode> modesForField(String field) {
  if (field == 'Date' ||
      field == 'StudyRating' ||
      field == 'WhiteElo' ||
      field == 'BlackElo') {
    return MatchMode.values;
  }
  return [
    MatchMode.contains,
    MatchMode.notContains,
    MatchMode.exact,
    MatchMode.regex,
  ];
}

/// Mutable header filter row.
class HeaderFilterRow {
  String field;
  MatchMode mode;
  String value;
  final TextEditingController controller;

  HeaderFilterRow({
    this.field = 'Black',
    this.mode = MatchMode.contains,
    String initialValue = '',
  })  : value = initialValue,
        controller = TextEditingController(text: initialValue);

  HeaderFilterConfig toConfig() =>
      HeaderFilterConfig(field: field, mode: mode, value: value);
}

// ── Controller ───────────────────────────────────────────────────────────────

final _sanTokenPattern = RegExp(r'^[a-hKQRBNO0-9x+#=]+$');

class SliceFilterController extends ChangeNotifier {
  SliceFilterController({SliceConfig? initialConfig}) {
    _applyConfig(initialConfig);
  }

  // ── Position filter ──

  final TextEditingController positionText = TextEditingController();
  PositionParseResult _positionParse = const PositionParseResult.ok(null);

  PositionParseResult get positionParse => _positionParse;
  String? get positionFen => _positionParse.fen;
  bool get hasPositionFilter => _positionParse.isValid && positionFen != null;

  /// Parse [positionText] and activate the position filter.
  void applyPosition() {
    _positionParse = parsePositionInput(positionText.text);
    notifyListeners();
  }

  void clearPosition() {
    positionText.clear();
    _positionParse = const PositionParseResult.ok(null);
    notifyListeners();
  }

  // ── Sequence filter ──

  final TextEditingController sequenceText = TextEditingController();
  final TextEditingController gapText = TextEditingController();
  String? _sequenceError;

  String? get sequenceError => _sequenceError;

  /// Parsed sequence groups (or empty).
  List<List<String>> get sequenceGroups {
    final text = sequenceText.text.trim();
    if (text.isEmpty) return const [];
    return pgn.parseSequenceGroups(text);
  }

  /// Current max-gap setting.
  int get sequenceGap => int.tryParse(gapText.text) ?? 4;

  bool get hasSequenceFilter => sequenceText.text.trim().isNotEmpty;

  /// Validate [sequenceText], updating [sequenceError].
  void validateSequence() {
    final text = sequenceText.text.trim();
    if (text.isEmpty) {
      _sequenceError = null;
      notifyListeners();
      return;
    }
    final parsed = pgn.parseSequenceGroups(text);
    if (parsed.isEmpty) {
      _sequenceError = 'No valid moves found';
      notifyListeners();
      return;
    }
    for (final group in parsed) {
      for (final san in group) {
        if (!_sanTokenPattern.hasMatch(san)) {
          _sequenceError = "Invalid move token: '$san'";
          notifyListeners();
          return;
        }
      }
    }
    _sequenceError = null;
    notifyListeners();
  }

  /// Gap edits only matter while a sequence is set.
  void sequenceGapChanged() {
    if (hasSequenceFilter) notifyListeners();
  }

  // ── Header filters ──

  final List<HeaderFilterRow> headerRows = [];

  /// Current filter configs (non-empty values only).
  List<HeaderFilterConfig> get headerConfigs => headerRows
      .where((f) => f.value.isNotEmpty)
      .map((f) => f.toConfig())
      .toList();

  /// Raw filter data for slice computation.
  List<({String field, MatchMode mode, String value})> get rawHeaderFilters =>
      headerRows
          .where((f) => f.value.isNotEmpty)
          .map((f) => (field: f.field, mode: f.mode, value: f.value))
          .toList();

  void addHeaderRow() {
    headerRows.add(HeaderFilterRow());
    notifyListeners();
  }

  void removeHeaderRow(int index) {
    headerRows[index].controller.dispose();
    headerRows.removeAt(index);
    notifyListeners();
  }

  void setHeaderField(int index, String field) {
    final row = headerRows[index];
    row.field = field;
    final modes = modesForField(field);
    if (!modes.contains(row.mode)) {
      row.mode = modes.first;
    } else if (isNumericField(field) && row.mode == MatchMode.contains) {
      row.mode = MatchMode.after;
    }
    notifyListeners();
  }

  void setHeaderMode(int index, MatchMode mode) {
    headerRows[index].mode = mode;
    notifyListeners();
  }

  void setHeaderValue(int index, String value) {
    headerRows[index].value = value;
    notifyListeners();
  }

  // ── Whole-config operations ──

  /// Snapshot the current filters as a serializable config.
  SliceConfig buildConfig() => SliceConfig(
        positionInput: positionFen,
        headerFilters: headerConfigs,
        sequencePattern: hasSequenceFilter
            ? sequenceGroups.map((g) => g.join(' ')).join(' [gap] ')
            : null,
        sequenceGap: sequenceGap,
      );

  /// Clear all filters back to their defaults.
  void reset() {
    for (final row in headerRows) {
      row.controller.dispose();
    }
    headerRows.clear();
    _applyConfig(null);
    notifyListeners();
  }

  void _applyConfig(SliceConfig? config) {
    positionText.text = config?.positionInput ?? '';
    _positionParse = positionText.text.isNotEmpty
        ? parsePositionInput(positionText.text)
        : const PositionParseResult.ok(null);

    sequenceText.text = config?.sequencePattern ?? '';
    gapText.text = '${config?.sequenceGap ?? 4}';
    _sequenceError = null;

    for (final f in config?.headerFilters ?? const <HeaderFilterConfig>[]) {
      if (f.value.isEmpty) continue;
      headerRows.add(HeaderFilterRow(
        field: kHeaderFieldOptions.contains(f.field) ? f.field : 'Black',
        mode: f.mode,
        initialValue: f.value,
      ));
    }
    if (headerRows.isEmpty) {
      headerRows.add(HeaderFilterRow(field: 'Date', mode: MatchMode.after));
    }
  }

  @override
  void dispose() {
    positionText.dispose();
    sequenceText.dispose();
    gapText.dispose();
    for (final row in headerRows) {
      row.controller.dispose();
    }
    super.dispose();
  }
}
