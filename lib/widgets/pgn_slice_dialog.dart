/// Slice dialog — filter a PGN game collection by board position and headers.
///
/// The data models ([SliceConfig], [MatchMode], [HeaderFilterConfig]) now live
/// in `lib/models/pgn_filter_models.dart` and are re-exported here for
/// backward compatibility.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../models/pgn_filter_models.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../utils/fen_utils.dart';
import 'lines_preview_panel.dart';
import 'position_preview_icon.dart';

export '../models/pgn_filter_models.dart';

// ---------------------------------------------------------------------------
// Internal mutable filter row used inside the dialog
// ---------------------------------------------------------------------------

class _HeaderFilter {
  String field;
  MatchMode mode;
  String value;
  final TextEditingController controller;

  _HeaderFilter({
    this.field = 'Black',
    this.mode = MatchMode.contains,
    String initialValue = '',
  })  : value = initialValue,
        controller = TextEditingController(text: initialValue);
}

// ---------------------------------------------------------------------------
// Position input parsing
// ---------------------------------------------------------------------------

/// Result of attempting to parse a position input string.
class _PositionParseResult {
  final String? fen;
  final String? error;
  const _PositionParseResult.ok(this.fen) : error = null;
  const _PositionParseResult.err(this.error) : fen = null;
  bool get isValid => fen != null;
}

/// Try to interpret [input] as either a FEN or a SAN move sequence.
_PositionParseResult _parsePositionInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const _PositionParseResult.ok(null);

  // Heuristic: FEN strings contain '/' for rank separators.
  if (trimmed.contains('/')) {
    try {
      final fullFen = expandFen(trimmed);
      // Validate by actually creating a position from it.
      Chess.fromSetup(Setup.parseFen(fullFen));
      return _PositionParseResult.ok(normalizeFen(fullFen));
    } catch (e) {
      return _PositionParseResult.err('Invalid FEN: $e');
    }
  }

  // Otherwise treat as SAN move sequence: "1. e4 c6 2. d4 d5" etc.
  return _parseSanSequence(trimmed);
}

_PositionParseResult _parseSanSequence(String input) {
  // Strip move numbers, dots, result tokens.
  final tokens = input
      .replaceAll(RegExp(r'\d+\.+'), '')
      .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  if (tokens.isEmpty) {
    return const _PositionParseResult.err('No moves found');
  }

  Position pos = Chess.initial;
  for (int i = 0; i < tokens.length; i++) {
    try {
      final move = pos.parseSan(tokens[i]);
      if (move == null) {
        return _PositionParseResult.err(
            "Could not parse move ${i + 1}: '${tokens[i]}'");
      }
      pos = pos.play(move);
    } catch (e) {
      return _PositionParseResult.err("Invalid move ${i + 1}: '${tokens[i]}'");
    }
  }
  return _PositionParseResult.ok(normalizeFen(pos.fen));
}

// ---------------------------------------------------------------------------
// ECO validation
// ---------------------------------------------------------------------------

final _ecoExact = RegExp(r'^[A-E]\d{2}$');
bool _isValidEco(String value) => _ecoExact.hasMatch(value.trim());

// ---------------------------------------------------------------------------
// Dialog types
// ---------------------------------------------------------------------------

/// Callback signature: passes matching indices + the config that produced them.
typedef SliceApplyCallback = void Function(
    List<int> matchingIndices, SliceConfig config);

// ---------------------------------------------------------------------------
// Isolate-safe slice compute — delegates to centralized helpers.
// ---------------------------------------------------------------------------

// Slice compute is delegated to pgn.computeSliceMatches (shared with
// InlineSliceEditor and applySliceConfig).

// ---------------------------------------------------------------------------
// PgnSliceDialog
// ---------------------------------------------------------------------------

class PgnSliceDialog extends StatefulWidget {
  final List<GameRecord> allGames;
  final String currentFen;
  final SliceApplyCallback onApply;

  /// Pre‑populate the dialog from a previously saved config.
  final SliceConfig? initialConfig;

  /// Precomputed FEN → game-index map for instant position lookups.
  final Map<String, List<int>>? fenIndex;

  const PgnSliceDialog({
    super.key,
    required this.allGames,
    required this.currentFen,
    required this.onApply,
    this.initialConfig,
    this.fenIndex,
  });

  @override
  State<PgnSliceDialog> createState() => _PgnSliceDialogState();
}

class _PgnSliceDialogState extends State<PgnSliceDialog> {
  final List<_HeaderFilter> _headerFilters = [];
  List<int> _matchingIndices = [];
  bool _computing = false;

  // Position filter
  final TextEditingController _positionController = TextEditingController();
  _PositionParseResult _positionParse = const _PositionParseResult.ok(null);

  // Sequence filter
  final TextEditingController _sequenceController = TextEditingController();
  final TextEditingController _gapController = TextEditingController(text: '4');
  String? _sequenceError;

  static const _fieldOptions = [
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

  static List<MatchMode> _modesForField(String field) {
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
      MatchMode.regex
    ];
  }

  @override
  void initState() {
    super.initState();
    _restoreFromConfig(widget.initialConfig);
    if (_headerFilters.isEmpty) {
      _headerFilters.add(_HeaderFilter(field: 'Date', mode: MatchMode.after));
    }
    _recompute();
  }

  void _restoreFromConfig(SliceConfig? config) {
    if (config == null || config.isEmpty) return;
    if (config.positionInput != null && config.positionInput!.isNotEmpty) {
      _positionController.text = config.positionInput!;
      _positionParse = _parsePositionInput(config.positionInput!);
    }
    if (config.sequencePattern != null && config.sequencePattern!.isNotEmpty) {
      _sequenceController.text = config.sequencePattern!;
    }
    if (config.sequenceGap != 4) {
      _gapController.text = config.sequenceGap.toString();
    }
    for (final f in config.headerFilters) {
      if (f.value.isEmpty) continue;
      _headerFilters.add(_HeaderFilter(
        field: _fieldOptions.contains(f.field) ? f.field : 'Black',
        mode: f.mode,
        initialValue: f.value,
      ));
    }
  }

  /// Parse the position input and recompute matches. Called explicitly by the
  /// user (button press or Enter key), not on every keystroke.
  void _applyPositionInput() {
    setState(() {
      _positionParse = _parsePositionInput(_positionController.text);
    });
    _recompute();
  }

  void _clearPositionInput() {
    _positionController.clear();
    setState(() {
      _positionParse = const _PositionParseResult.ok(null);
    });
    _recompute();
  }

  bool get _hasPositionFilter =>
      _positionParse.isValid && _positionParse.fen != null;

  /// True when the position text field has content that hasn't been applied yet.
  bool get _hasUnappliedInput {
    final text = _positionController.text.trim();
    if (text.isEmpty) return false;
    // If we already parsed and it matches, it's applied.
    if (_positionParse.isValid && _positionParse.fen != null) return false;
    // If it errored, it's been attempted (error is shown).
    if (_positionParse.error != null) return false;
    // Text present but parse result is still null (never applied).
    return true;
  }

  SliceConfig _buildConfig() {
    final filters = _headerFilters
        .where((f) => f.value.isNotEmpty)
        .map((f) =>
            HeaderFilterConfig(field: f.field, mode: f.mode, value: f.value))
        .toList();
    return SliceConfig(
      positionInput: _positionController.text.trim().isEmpty
          ? null
          : _positionController.text.trim(),
      headerFilters: filters,
      sequencePattern: _sequenceController.text.trim().isEmpty
          ? null
          : _sequenceController.text.trim(),
      sequenceGap: int.tryParse(_gapController.text) ?? 4,
    );
  }

  void _addFilter() {
    setState(() => _headerFilters.add(_HeaderFilter()));
  }

  void _removeFilter(int i) {
    setState(() {
      _headerFilters[i].controller.dispose();
      _headerFilters.removeAt(i);
    });
    _recompute();
  }

  int _computeGeneration = 0;
  String? _lastFilterFingerprint;
  Timer? _recomputeDebounce;

  String _effectiveFilterFingerprint() {
    final parts = <String>[];
    if (_hasPositionFilter) {
      parts.add('fen:${_positionParse.fen}');
    }
    for (final f in _headerFilters.where((f) => f.value.isNotEmpty)) {
      parts.add('h:${f.field}|${f.mode.name}|${f.value}');
    }
    final seqText = _sequenceController.text.trim();
    if (seqText.isNotEmpty) {
      final seqGap = int.tryParse(_gapController.text) ?? 4;
      final groups = pgn.parseSequenceGroups(seqText);
      parts.add(
          'seq:$seqText|gap:$seqGap|${groups.map((g) => g.join(',')).join(';')}');
    }
    return parts.join('\n');
  }

  void _scheduleRecompute() {
    _recomputeDebounce?.cancel();
    _recomputeDebounce = Timer(const Duration(milliseconds: 300), _recompute);
  }

  void _recompute() {
    final fingerprint = _effectiveFilterFingerprint();
    if (fingerprint == _lastFilterFingerprint) return;
    _lastFilterFingerprint = fingerprint;

    final generation = ++_computeGeneration;
    setState(() => _computing = true);

    final targetFen = _hasPositionFilter ? _positionParse.fen : null;
    final filters = _headerFilters
        .where((f) => f.value.isNotEmpty)
        .map((f) => (field: f.field, mode: f.mode, value: f.value))
        .toList();
    final games = widget.allGames;

    final seqText = _sequenceController.text.trim();
    final seqGroups = seqText.isNotEmpty
        ? pgn.parseSequenceGroups(seqText)
        : const <List<String>>[];
    final seqGap = int.tryParse(_gapController.text) ?? 4;

    pgn
        .computeSliceMatches(
      games: games,
      targetFen: targetFen,
      filters: filters,
      seqGroups: seqGroups,
      seqGap: seqGap,
      fenIndex: widget.fenIndex,
    )
        .then((indices) {
      if (!mounted || generation != _computeGeneration) return;
      setState(() {
        _matchingIndices = indices;
        _computing = false;
      });
    });
  }

  @override
  void dispose() {
    _recomputeDebounce?.cancel();
    _positionController.dispose();
    _sequenceController.dispose();
    _gapController.dispose();
    for (final f in _headerFilters) {
      f.controller.dispose();
    }
    super.dispose();
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Slice Dataset'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPositionSection(),
              const Divider(),
              _buildSequenceSection(),
              const Divider(),
              _buildHeaderSection(),
              const SizedBox(height: 16),
              _buildResultsPreview(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              _positionController.clear();
              _sequenceController.clear();
              _gapController.text = '4';
              _sequenceError = null;
              for (final f in _headerFilters) {
                f.controller.dispose();
              }
              _headerFilters.clear();
              _headerFilters
                  .add(_HeaderFilter(field: 'Date', mode: MatchMode.after));
            });
            _recompute();
          },
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _matchingIndices.isNotEmpty || _hasUnappliedInput
              ? () {
                  if (_hasUnappliedInput) {
                    _applyPositionInput();
                    // After applying, wait for recompute then the user can
                    // click Apply again with the updated count.
                    return;
                  }
                  widget.onApply(_matchingIndices, _buildConfig());
                  Navigator.pop(context);
                }
              : null,
          child: Text(_hasUnappliedInput
              ? 'Apply position filter first'
              : _computing
                  ? 'Apply (${_matchingIndices.isEmpty ? '…' : _matchingIndices.length})'
                  : 'Apply (${_matchingIndices.length})'),
        ),
      ],
    );
  }

  // ── Position section ──

  Widget _buildPositionSection() {
    final showError = _positionParse.error != null;
    final showOk = _positionParse.isValid && _positionParse.fen != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Position Filter',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _positionController,
                decoration: InputDecoration(
                  hintText: 'FEN or moves, e.g. 1. e4 c6',
                  hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: const OutlineInputBorder(),
                  suffixIcon: showOk || showError
                      ? Icon(
                          showOk ? Icons.check_circle : Icons.error_outline,
                          size: 18,
                          color: showOk ? Colors.green : Colors.red,
                        )
                      : null,
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 32, minHeight: 28),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                onSubmitted: (_) => _applyPositionInput(),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              height: 36,
              child: OutlinedButton(
                onPressed: _applyPositionInput,
                child: const Text('Apply', style: TextStyle(fontSize: 12)),
              ),
            ),
            if (_positionController.text.isNotEmpty)
              PositionPreviewIcon(inputGetter: () => _positionController.text),
            if (_hasPositionFilter || _positionController.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: _clearPositionInput,
                  tooltip: 'Clear position filter',
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (showError)
              Expanded(
                child: Text(
                  _positionParse.error!,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            _buildBoardPositionChip(),
          ],
        ),
      ],
    );
  }

  Widget _buildBoardPositionChip() {
    const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    final normalizedCurrent = normalizeFen(widget.currentFen);
    final isStart = normalizedCurrent == startFen;
    final isActive = _hasPositionFilter &&
        normalizeFen(_positionController.text.trim()) == normalizedCurrent;

    return Tooltip(
      message: isStart
          ? 'Navigate to a position on the board first'
          : isActive
              ? 'Remove board position filter'
              : 'Use the current board position',
      child: GestureDetector(
        onTap: isStart
            ? null
            : () {
                if (isActive) {
                  _clearPositionInput();
                } else {
                  _positionController.text = widget.currentFen;
                  _applyPositionInput();
                }
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isStart
                ? Colors.grey[800]
                : isActive
                    ? Colors.blue[700]
                    : Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? Colors.blue[400]! : Colors.grey[700]!,
              width: isActive ? 1.5 : 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isActive ? Icons.grid_on : Icons.grid_on,
                size: 12,
                color: isStart
                    ? Colors.grey[600]
                    : isActive
                        ? Colors.blue[100]
                        : Colors.grey[400],
              ),
              const SizedBox(width: 4),
              Text(
                'Board position',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isStart
                      ? Colors.grey[600]
                      : isActive
                          ? Colors.blue[100]
                          : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sequence filter section ──

  void _validateSequence() {
    final text = _sequenceController.text.trim();
    if (text.isEmpty) {
      setState(() => _sequenceError = null);
      _recompute();
      return;
    }
    final groups = pgn.parseSequenceGroups(text);
    if (groups.isEmpty) {
      setState(() => _sequenceError = 'No valid moves found');
      return;
    }
    // Validate each SAN token is plausible (basic check — not full legality)
    for (final group in groups) {
      for (final san in group) {
        if (!RegExp(r'^[a-hKQRBNO0-9x+#=]+$').hasMatch(san)) {
          setState(() => _sequenceError = "Invalid move token: '$san'");
          return;
        }
      }
    }
    setState(() => _sequenceError = null);
    _recompute();
  }

  Widget _buildSequenceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Move Sequence Filter',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Find games containing specific moves in order. '
          'Use [gap] between groups that need not be consecutive.',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _sequenceController,
          decoration: InputDecoration(
            hintText: 'e.g.  d5 e5 [gap] f6',
            hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: const OutlineInputBorder(),
            suffixIcon: _sequenceController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () {
                      _sequenceController.clear();
                      _validateSequence();
                    },
                  )
                : null,
            suffixIconConstraints:
                const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          onChanged: (_) => _validateSequence(),
          onSubmitted: (_) => _validateSequence(),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (_sequenceError != null)
              Expanded(
                child: Text(
                  _sequenceError!,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            Text('Max gap: ',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
            SizedBox(
              width: 40,
              child: TextField(
                controller: _gapController,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                keyboardType: TextInputType.number,
                onChanged: (_) {
                  if (_sequenceController.text.trim().isNotEmpty) {
                    _recompute();
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
            Text('ply',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          ],
        ),
      ],
    );
  }

  // ── Header filters section ──

  Widget _buildHeaderSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Header Filters',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < _headerFilters.length; i++) _buildFilterRow(i),
        TextButton.icon(
          onPressed: _addFilter,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add filter'),
        ),
      ],
    );
  }

  Widget _buildFilterRow(int index) {
    final f = _headerFilters[index];
    final availableModes = _modesForField(f.field);
    if (!availableModes.contains(f.mode)) {
      f.mode = availableModes.first;
    }

    String hintText;
    if (f.field == 'ECO') {
      hintText = 'e.g. B12 or B1';
    } else if (f.field == 'Date') {
      hintText = 'e.g. 2000';
    } else if (f.field == 'StudyRating') {
      hintText = 'e.g. 3';
    } else if (f.field == 'WhiteElo' || f.field == 'BlackElo') {
      hintText = 'e.g. 2400';
    } else {
      hintText = 'Value...';
    }

    // ECO validation warning
    final showEcoWarn = f.field == 'ECO' &&
        f.mode == MatchMode.exact &&
        f.value.isNotEmpty &&
        !_isValidEco(f.value);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Field dropdown
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<String>(
                  initialValue: f.field,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  items: _fieldOptions
                      .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s, style: const TextStyle(fontSize: 12))))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      f.field = v!;
                      final modes = _modesForField(f.field);
                      if (!modes.contains(f.mode)) {
                        f.mode = modes.first;
                      } else if (isNumericField(f.field) &&
                          f.mode == MatchMode.contains) {
                        f.mode = MatchMode.after;
                      }
                    });
                    if (f.value.isNotEmpty) {
                      _recompute();
                    }
                  },
                ),
              ),
              const SizedBox(width: 6),
              // Match mode dropdown
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<MatchMode>(
                  initialValue: f.mode,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  items: availableModes
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(
                                matchModeLabel(m,
                                    numeric: isNumericField(f.field)),
                                style: const TextStyle(fontSize: 12)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    setState(() => f.mode = v!);
                    if (f.value.isNotEmpty) {
                      _recompute();
                    }
                  },
                ),
              ),
              const SizedBox(width: 6),
              // Value text field
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: hintText,
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    border: const OutlineInputBorder(),
                    suffixIcon: showEcoWarn
                        ? Tooltip(
                            message: 'Not a standard ECO code (A00–E99)',
                            child: Icon(Icons.warning_amber,
                                size: 16, color: Colors.orange[400]),
                          )
                        : null,
                    suffixIconConstraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) {
                    f.value = v;
                    _scheduleRecompute();
                  },
                  controller: f.controller,
                ),
              ),
              const SizedBox(width: 4),
              // Remove button
              IconButton(
                onPressed: () => _removeFilter(index),
                icon: const Icon(Icons.close, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
          if (showEcoWarn)
            Padding(
              padding: const EdgeInsets.only(left: 248, top: 2),
              child: Text(
                'Expected A00–E99',
                style: TextStyle(fontSize: 10, color: Colors.orange[400]),
              ),
            ),
        ],
      ),
    );
  }

  // ── Results preview ──

  Widget _buildResultsPreview() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 200,
          child: LinesPreviewPanel(
            allGames: widget.allGames,
            matchedIndices: _matchingIndices,
            computing: _computing,
            maxHeight: 200,
          ),
        ),
      ],
    );
  }
}
