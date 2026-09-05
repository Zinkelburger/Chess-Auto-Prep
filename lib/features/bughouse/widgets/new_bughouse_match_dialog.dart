/// Setting a bughouse tournament up: which position, how many games, how
/// hard the two teams think.
///
/// Shaped after `new_tournament_dialog.dart` next door — name, position,
/// games, strength, and everything else behind one **Advanced** disclosure
/// with defaults you would pick anyway. The knobs that mean nothing here are
/// left out rather than shown greyed: no clock, because Hivemind has no
/// clock; no depth, because an MCTS search has no depth to fix; no engine
/// picker, because there is one bughouse engine. Every quantity is a number
/// you type inside a range, not a menu of presets.
///
/// The one input with no counterpart on the chess side is the **opening**. A
/// bughouse position is two boards, so "the position" cannot be a FEN in a
/// box — it is either what the lab already has on screen, a line typed out,
/// or a dual FEN. All three end up as the same thing: a [BughouseState] the
/// tournament starts every game from.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_state.dart';
import '../models/bughouse_tournament.dart';
import 'bughouse_number_field.dart';
import 'bughouse_panel_section.dart';

Future<void> showNewBughouseMatchDialog(
  BuildContext context,
  BughouseController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _NewBughouseMatchDialog(controller: controller),
);

/// Where the games start from.
enum _Source { boards, line, fen }

class _NewBughouseMatchDialog extends StatefulWidget {
  const _NewBughouseMatchDialog({required this.controller});

  final BughouseController controller;

  @override
  State<_NewBughouseMatchDialog> createState() =>
      _NewBughouseMatchDialogState();
}

class _NewBughouseMatchDialogState extends State<_NewBughouseMatchDialog> {
  late final TextEditingController _name = TextEditingController(
    text: _defaultName(),
  );
  final TextEditingController _line = TextEditingController();
  final TextEditingController _fen = TextEditingController();

  _Source _source = _Source.boards;

  int _games = 10;
  int _nodesA = 800;
  int _nodesB = 800;
  bool _alternateSeats = true;
  BughouseTimeStance _stance = BughouseTimeStance.level;
  BughouseVariety _variety = const BughouseVariety();
  int _maxPlies = 240;
  late int _hashMb = widget.controller.engineSettings.hashMb;
  late int _batchSize = widget.controller.engineSettings.batchSize;

  static const int minGames = 1;
  static const int maxGames = 1000;
  static const int minNodes = 50;
  static const int maxNodes = 1000000;
  static const int maxVarietyPlies = 60;
  static const int minPlyLimit = 20;
  static const int maxPlyLimit = 2000;

  @override
  void initState() {
    super.initState();
    _line.text = _movetextOfBoards();
    _fen.text = widget.controller.state.dualFen;
  }

  @override
  void dispose() {
    _name.dispose();
    _line.dispose();
    _fen.dispose();
    super.dispose();
  }

  /// The lab's own line, named after the opening it plays — `d4 d5 Bf4` — so
  /// the run is findable later without typing anything.
  String _defaultName() {
    final line = widget.controller.history
        .movetextOn(BughouseBoard.a)
        .map((e) => e.ply.san)
        .take(6)
        .join(' ');
    return line.isEmpty ? 'Bughouse tournament' : line;
  }

  String _movetextOfBoards() {
    final history = widget.controller.history;
    final a = history.movetextFor(BughouseBoard.a);
    final b = history.movetextFor(BughouseBoard.b);
    if (a.isEmpty && b.isEmpty) return '';
    return b.isEmpty ? a : '1: $a\n2: $b';
  }

  /// The position the games would start from, or the reason there is none.
  ({BughouseState state, String label})? get _start {
    switch (_source) {
      case _Source.boards:
        final history = widget.controller.history;
        return (
          state: widget.controller.state,
          label: history.isEmpty
              ? 'The position on the boards'
              // Not `tableMovetext`: that names both boards whatever is on
              // them, which is right for a paste — the shape of the text
              // should not change with the game — and wrong for a one-line
              // summary, where an empty "Board 2:" is just noise.
              : [
                  for (final which in BughouseBoard.values)
                    if (history.movetextFor(which).isNotEmpty)
                      '${which.label}: ${history.movetextFor(which)}',
                ].join('  ·  '),
        );
      case _Source.line:
        return parseBughouseOpening(_line.text);
      case _Source.fen:
        final parsed = BughouseState.tryParseDualFen(_fen.text);
        return parsed == null ? null : (state: parsed, label: _fen.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = _start;
    return AlertDialog(
      title: const Text('New bughouse tournament', style: AppTextStyles.title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                style: AppTextStyles.body,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),

              const BughousePanelLabel('Every game starts from'),
              SegmentedButton<_Source>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                    value: _Source.boards,
                    label: Text('The boards'),
                    tooltip: 'The position and line currently in the lab',
                  ),
                  ButtonSegment(
                    value: _Source.line,
                    label: Text('A line'),
                    tooltip: 'Type the opening out in SAN',
                  ),
                  ButtonSegment(
                    value: _Source.fen,
                    label: Text('A dual FEN'),
                    tooltip: 'Two crazyhouse FENs joined by a pipe',
                  ),
                ],
                selected: {_source},
                onSelectionChanged: (s) => setState(() => _source = s.first),
              ),
              if (_source == _Source.line) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _line,
                  style: AppTextStyles.mono,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '1. d4 d5 2. Bf4',
                    helperMaxLines: 2,
                    helperText:
                        'Board 1 unless a line starts with "2:". Board 1 is '
                        'played out before board 2.',
                  ),
                ),
              ],
              if (_source == _Source.fen) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _fen,
                  style: AppTextStyles.monoDense,
                  minLines: 2,
                  maxLines: 3,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '<board 1 FEN>|<board 2 FEN>',
                  ),
                ),
              ],
              const SizedBox(height: 8),
              _StartSummary(start: start),

              const SizedBox(height: 18),
              BughouseNumberField(
                key: const Key('bughouse-tournament-games'),
                label: 'Games',
                value: _games,
                min: minGames,
                max: maxGames,
                labelWidth: 120,
                onChanged: (v) => setState(() => _games = v),
              ),
              BughouseNumberField(
                key: const Key('bughouse-tournament-nodes-a'),
                label: 'A + C thinks',
                unit: 'nodes a move',
                hint:
                    'Nodes rather than seconds, so the same run replays. Give '
                    'one team more to ask whether the line holds against '
                    'someone thinking harder.',
                value: _nodesA,
                min: minNodes,
                max: maxNodes,
                labelWidth: 120,
                onChanged: (v) => setState(() => _nodesA = v),
              ),
              BughouseNumberField(
                key: const Key('bughouse-tournament-nodes-b'),
                label: 'B + D thinks',
                unit: 'nodes a move',
                value: _nodesB,
                min: minNodes,
                max: maxNodes,
                labelWidth: 120,
                onChanged: (v) => setState(() => _nodesB = v),
              ),

              const SizedBox(height: 12),
              BughousePanelSection(
                title: 'Advanced',
                summary:
                    '${_variety.isOn ? 'Variety on' : 'Variety off'} · '
                    '${_alternateSeats ? 'seats swap' : 'seats fixed'} · '
                    '${_stance.shortLabel} · $_maxPlies ply limit',
                children: [
                  const BughousePanelLabel('Variety'),
                  BughouseNumberField(
                    label: 'Sampled plies',
                    hint:
                        'How many opening plies are drawn from the engine\'s '
                        'shortlist rather than its top line. 0 plays the '
                        'same game every time.',
                    value: _variety.plies,
                    min: 0,
                    max: maxVarietyPlies,
                    labelWidth: 120,
                    onChanged: (v) =>
                        setState(() => _variety = _variety.copyWith(plies: v)),
                  ),
                  BughouseNumberField(
                    label: 'Candidates',
                    hint: 'How many ranked lines each sampled ply picks from.',
                    value: _variety.lines,
                    min: 1,
                    max: 10,
                    labelWidth: 120,
                    onChanged: (v) =>
                        setState(() => _variety = _variety.copyWith(lines: v)),
                  ),
                  BughouseNumberField(
                    label: 'Window',
                    unit: '% of value',
                    hint:
                        'How far below the best line a sampled move may be, '
                        'in hundredths of the engine\'s value.',
                    value: (_variety.window * 100).round(),
                    min: 1,
                    max: 50,
                    labelWidth: 120,
                    onChanged: (v) => setState(
                      () => _variety = _variety.copyWith(window: v / 100),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _alternateSeats,
                    onChanged: (v) => setState(() => _alternateSeats = v),
                    title: const Text(
                      'Swap seats every other game',
                      style: AppTextStyles.body,
                    ),
                    subtitle: const Text(
                      'Off, every game is the same side of the line.',
                      style: AppTextStyles.hint,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const BughousePanelLabel('Clock stance, for the whole run'),
                  SegmentedButton<BughouseTimeStance>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: BughouseTimeStance.ahead,
                        label: Text('White on 1 ahead'),
                        tooltip: 'That pair may sit on both boards',
                      ),
                      ButtonSegment(
                        value: BughouseTimeStance.level,
                        label: Text('Level'),
                        tooltip: 'Nobody may sit on both boards',
                      ),
                      ButtonSegment(
                        value: BughouseTimeStance.behind,
                        label: Text('Black on 1 ahead'),
                        tooltip: 'That pair may sit on both boards',
                      ),
                    ],
                    selected: {_stance},
                    onSelectionChanged: (s) =>
                        setState(() => _stance = s.first),
                  ),
                  const SizedBox(height: 10),
                  BughouseNumberField(
                    label: 'Ply limit',
                    hint: 'A game that reaches it is filed as a draw.',
                    value: _maxPlies,
                    min: minPlyLimit,
                    max: maxPlyLimit,
                    labelWidth: 120,
                    onChanged: (v) => setState(() => _maxPlies = v),
                  ),
                  BughouseNumberField(
                    label: 'Memory',
                    unit: 'MB',
                    value: _hashMb,
                    min: BughouseEngineSettings.hashMin,
                    max: BughouseEngineSettings.hashMax,
                    labelWidth: 120,
                    onChanged: (v) => setState(() => _hashMb = v),
                  ),
                  BughouseNumberField(
                    label: 'Batch',
                    value: _batchSize,
                    min: BughouseEngineSettings.batchMin,
                    max: BughouseEngineSettings.batchMax,
                    labelWidth: 120,
                    onChanged: (v) => setState(() => _batchSize = v),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: start == null ? null : () => _start_(start),
          child: Text('Play $_games game${_games == 1 ? '' : 's'}'),
        ),
      ],
    );
  }

  void _start_(({BughouseState state, String label}) start) {
    final name = _name.text.trim();
    final config = BughouseTournamentConfig(
      name: name.isEmpty ? 'Bughouse tournament' : name,
      startDualFen: start.state.dualFen,
      openingLabel: start.label,
      participants: [
        BughouseParticipant(
          name: 'A + C',
          budget: BughouseBudget.nodes(_nodesA),
        ),
        BughouseParticipant(
          name: 'B + D',
          budget: BughouseBudget.nodes(_nodesB),
        ),
      ],
      games: _games,
      alternateSeats: _alternateSeats,
      timeStance: _stance,
      maxPlies: _maxPlies,
      hashMb: _hashMb,
      batchSize: _batchSize,
      variety: _variety,
    );
    Navigator.of(context).pop();
    unawaited(widget.controller.tournaments.start(config));
  }
}

/// What the chosen source parsed to — or that it did not.
class _StartSummary extends StatelessWidget {
  const _StartSummary({required this.start});

  final ({BughouseState state, String label})? start;

  @override
  Widget build(BuildContext context) {
    final parsed = start;
    if (parsed == null) {
      return const Text(
        'That is not a position yet — check the moves or the FEN.',
        style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.danger),
      );
    }
    return Text(
      parsed.label.isEmpty ? 'The starting position' : parsed.label,
      style: AppTextStyles.caption,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ------------------------------------------------------------------ parsing

/// Reads a typed opening into a two-board position.
///
/// The format is the one a player would write: `1. d4 d5 2. Bf4` for board 1,
/// and a line prefixed `2:` (or `B:`, or `Board 2:`) for board 2. Move numbers
/// and the `...` before a black move are decoration and are thrown away — what
/// matters is the order of the SAN tokens on each board.
///
/// **Board 1 is played through before board 2**, which is a real limitation
/// and is why it is stated in the field's own hint: in bughouse a capture
/// hands a piece to the other board, so two orderings of the same two lines
/// can produce different reserves. It only bites on an opening containing a
/// capture, and the alternative — asking a player to interleave the two boards
/// by hand — would be worse for every opening that does not.
///
/// Returns null when a token is not a legal move on the board it was given to,
/// which is what the dialog reports as "that is not a position yet".
({BughouseState state, String label})? parseBughouseOpening(String text) {
  if (text.trim().isEmpty) {
    return (state: BughouseState.initial(), label: 'The starting position');
  }
  final perBoard = <BughouseBoard, List<String>>{
    BughouseBoard.a: [],
    BughouseBoard.b: [],
  };
  var current = BughouseBoard.a;
  for (final rawLine in text.split(RegExp(r'[\n;]'))) {
    var line = rawLine.trim();
    if (line.isEmpty) continue;
    final prefix = RegExp(
      r'^(?:board\s*)?([12ab])\s*[:.]\s*',
      caseSensitive: false,
    ).firstMatch(line);
    if (prefix != null) {
      final key = prefix.group(1)!.toLowerCase();
      current = (key == '2' || key == 'b') ? BughouseBoard.b : BughouseBoard.a;
      line = line.substring(prefix.end);
    }
    for (final token in line.split(RegExp(r'\s+'))) {
      final san = token.trim();
      if (san.isEmpty) continue;
      // `12.`, `12...`, and a bare `...` continuing a line.
      if (RegExp(r'^\d+\.*$').hasMatch(san)) continue;
      if (san == '...' || san == '*') continue;
      // A trailing move number glued to the move, as `2.Bf4` is usually typed.
      final stripped = san.replaceFirst(RegExp(r'^\d+\.+'), '');
      if (stripped.isEmpty) continue;
      perBoard[current]!.add(stripped);
    }
  }

  var state = BughouseState.initial();
  for (final which in BughouseBoard.values) {
    for (final san in perBoard[which]!) {
      final move = state.board(which).parseSan(san);
      if (move == null) return null;
      final next = state.playMove(which, move);
      if (next == null) return null;
      state = next;
    }
  }

  final label = [
    for (final which in BughouseBoard.values)
      if (perBoard[which]!.isNotEmpty)
        '${which.label}: ${perBoard[which]!.join(' ')}',
  ].join('  ·  ');
  return (state: state, label: label);
}
