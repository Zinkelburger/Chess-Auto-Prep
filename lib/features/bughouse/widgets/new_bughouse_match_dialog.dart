/// Setting a bughouse match up: which position, how many games, how hard the
/// two teams think.
///
/// Shaped after `new_tournament_dialog.dart` next door — same three-part form,
/// same "everything reproducible is snapshotted at start" contract — with the
/// knobs that mean nothing here left out rather than shown greyed. There is no
/// clock control, because Hivemind has no clock; no depth, because an MCTS
/// search has no depth to fix; and no engine picker, because there is one
/// bughouse engine.
///
/// The one input with no counterpart on the chess side is the **opening**. A
/// bughouse position is two boards, so "the position" cannot be a FEN in a box
/// — it is either what the lab already has on screen, a line typed out, or a
/// dual FEN. All three end up as the same thing: a [BughouseState] the match
/// starts every game from.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_state.dart';
import '../models/bughouse_tournament.dart';
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
  BughouseBudget _budgetA = const BughouseBudget.nodes(800);
  BughouseBudget _budgetB = const BughouseBudget.nodes(800);
  bool _alternateSeats = true;
  BughouseTimeStance _stance = BughouseTimeStance.level;
  BughouseVariety _variety = const BughouseVariety();
  int _maxPlies = 240;
  int _hashMb = 256;
  int _batchSize = 8;

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
  /// the match is findable later without typing anything.
  String _defaultName() {
    final line = widget.controller.history
        .movetextOn(BughouseBoard.a)
        .map((e) => e.ply.san)
        .take(6)
        .join(' ');
    return line.isEmpty ? 'Bughouse match' : line;
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
      title: const Text('New bughouse match', style: AppTextStyles.title),
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
                    helperMaxLines: 3,
                    helperText:
                        'Board 1 unless a line is prefixed "2:". Board 1 is '
                        'played out first, then board 2 — which matters only '
                        'if the opening contains a capture.',
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
              Row(
                children: [
                  Expanded(
                    child: _Dropdown<int>(
                      label: 'Games',
                      value: _games,
                      items: BughouseTournamentConfig.gameChoices,
                      labelOf: (v) => '$v',
                      onChanged: (v) => setState(() => _games = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Dropdown<int>(
                      label: 'A + C thinks',
                      value: _budgetA.nodes ?? 800,
                      items: BughouseBudget.nodeChoices,
                      labelOf: (v) => '$v nodes',
                      onChanged: (v) =>
                          setState(() => _budgetA = BughouseBudget.nodes(v)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Dropdown<int>(
                      label: 'B + D thinks',
                      value: _budgetB.nodes ?? 800,
                      items: BughouseBudget.nodeChoices,
                      labelOf: (v) => '$v nodes',
                      onChanged: (v) =>
                          setState(() => _budgetB = BughouseBudget.nodes(v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Nodes rather than seconds, so a match run twice usually '
                'replays. Give one team more to ask whether the line holds '
                'against someone thinking harder.',
                style: AppTextStyles.hint,
              ),

              const SizedBox(height: 18),
              BughousePanelSection(
                title: 'Variety',
                summary: _variety.isOn
                    ? 'First ${_variety.plies} plies from the top '
                          '${_variety.lines}'
                    : 'Off — every game identical',
                children: [
                  const Text(
                    'The engine answers the same way every time, so without '
                    'this a ten-game match is one game played ten times. '
                    'Sampled moves come '
                    'from the engine\'s own shortlist, never from the legal '
                    'moves, so every game stays one it would defend.',
                    style: AppTextStyles.hint,
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<int>(
                    label: 'Sampled plies',
                    value: _variety.plies,
                    items: BughouseVariety.plyChoices,
                    labelOf: (v) => v == 0 ? 'Off' : '$v',
                    onChanged: (v) =>
                        setState(() => _variety = _variety.copyWith(plies: v)),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<int>(
                    label: 'Candidates per ply',
                    value: _variety.lines,
                    items: BughouseVariety.lineChoices,
                    labelOf: (v) => '$v',
                    onChanged: (v) =>
                        setState(() => _variety = _variety.copyWith(lines: v)),
                  ),
                  const SizedBox(height: 10),
                  _Dropdown<double>(
                    label: 'How far below the best a move may be',
                    value: _variety.window,
                    items: BughouseVariety.windowChoices,
                    labelOf: (v) => '$v of the engine\'s value',
                    onChanged: (v) =>
                        setState(() => _variety = _variety.copyWith(window: v)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              BughousePanelSection(
                title: 'Table and engine',
                summary:
                    '${_alternateSeats ? 'Seats swap' : 'Seats fixed'} · '
                    '${_stance.shortLabel} · $_maxPlies ply limit',
                children: [
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
                      'On, the crosstable measures the two engines and the '
                      'opening cancels out. Off, every game is the same side '
                      'of the line — which is what you want when both teams '
                      'are the same engine.',
                      style: AppTextStyles.hint,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const BughousePanelLabel('Clock stance, for the whole match'),
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
                  const SizedBox(height: 6),
                  const Text(
                    'Fixed, not simulated: teams take turns here, so a '
                    'simulated diagonal would never move. It is the one bit '
                    'the engine reads, and it decides whether sitting is '
                    'legal at all.',
                    style: AppTextStyles.hint,
                  ),
                  const SizedBox(height: 12),
                  _Dropdown<int>(
                    label: 'Ply limit, filed as a draw',
                    value: _maxPlies,
                    items: BughouseTournamentConfig.maxPlyChoices,
                    labelOf: (v) => '$v',
                    onChanged: (v) => setState(() => _maxPlies = v),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _Dropdown<int>(
                          label: 'Hash',
                          value: _hashMb,
                          items: const [16, 64, 256, 512, 1024, 2048],
                          labelOf: (v) => '$v MB',
                          onChanged: (v) => setState(() => _hashMb = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Dropdown<int>(
                          label: 'Batch',
                          value: _batchSize,
                          items: const [1, 4, 8, 16, 32, 64],
                          labelOf: (v) => '$v',
                          onChanged: (v) => setState(() => _batchSize = v),
                        ),
                      ),
                    ],
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
          child: Text('Play $_games games'),
        ),
      ],
    );
  }

  void _start_(({BughouseState state, String label}) start) {
    final name = _name.text.trim();
    // The stance the lab holds is relative to *its* team; the match's is
    // always relative to White on board 1, so a lab set up from Black's seat
    // has to be read the other way round.
    final config = BughouseTournamentConfig(
      name: name.isEmpty ? 'Bughouse match' : name,
      startDualFen: start.state.dualFen,
      openingLabel: start.label,
      participants: [
        BughouseParticipant(name: 'A + C', budget: _budgetA),
        BughouseParticipant(name: 'B + D', budget: _budgetB),
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

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      BughousePanelLabel(label),
      DropdownButtonFormField<T>(
        initialValue: value,
        isDense: true,
        style: AppTextStyles.body,
        decoration: const InputDecoration(isDense: true),
        items: [
          for (final item in items)
            DropdownMenuItem(value: item, child: Text(labelOf(item))),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    ],
  );
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
