/// Set up a match or a tournament.
///
/// The dialog shows only what people actually change: the position, the
/// name, how many games, and the time control. Everything else — which
/// engines play, the clock's exact numbers, concurrency, adjudication — sits
/// behind one **Advanced** toggle with defaults you would pick anyway: the
/// bundled Stockfish against itself, two seconds a move, ten games with the
/// colours alternating, one game at a time, and the adjudication rules that
/// stop two equal engines shuffling a dead position for two hundred moves.
///
/// The FEN field starts *empty*, and empty means the standard starting
/// position. A prefilled start FEN used to sit in the field, which made the
/// one thing people came to type into look like something they should not
/// touch.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../constants/chess_constants.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/fen_utils.dart';
import '../../../utils/system_info.dart';
import '../../../widgets/board_editor/board_editor_dialog.dart';
import '../../../widgets/common/static_board_thumbnail.dart';
import '../models/adjudication_rules.dart';
import '../models/engine_spec.dart';
import '../models/time_control.dart';
import '../models/tournament_config.dart';

Future<TournamentConfig?> showNewTournamentDialog(
  BuildContext context, {
  required List<EngineSpec> engines,
  required String boardFen,
  required VoidCallback onManageEngines,
}) {
  return showDialog<TournamentConfig>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: _NewTournamentBody(
          engines: engines,
          boardFen: boardFen,
          onManageEngines: onManageEngines,
        ),
      ),
    ),
  );
}

class _NewTournamentBody extends StatefulWidget {
  const _NewTournamentBody({
    required this.engines,
    required this.boardFen,
    required this.onManageEngines,
  });

  final List<EngineSpec> engines;

  /// Whatever position the app's board is showing, offered as one click.
  final String boardFen;

  final VoidCallback onManageEngines;

  @override
  State<_NewTournamentBody> createState() => _NewTournamentBodyState();
}

class _NewTournamentBodyState extends State<_NewTournamentBody> {
  static const _boardSize = 208.0;

  final _name = TextEditingController(text: 'Engine match');
  final _opening = TextEditingController();

  /// Empty means [kStandardStartFen]; see [_effectiveFen].
  final _fen = TextEditingController();

  /// Ids of the participants, in seeding order. The same engine may appear
  /// twice — that is how you test a change against its own baseline.
  late final List<String> _participants = [
    widget.engines.first.id,
    widget.engines.first.id,
  ];

  TimeControl _timeControl = const TimeControl.perMove(2000);
  int _gamesPerPairing = 10;
  bool _alternateColors = true;
  TournamentFormat _format = TournamentFormat.roundRobin;
  int _concurrency = 1;
  bool _annotateMoves = false;
  AdjudicationRules _adjudication = const AdjudicationRules();

  bool _showAdvanced = false;
  String? _fenError;

  @override
  void initState() {
    super.initState();
    _fen.addListener(_validateFen);
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    _fen.dispose();
    super.dispose();
  }

  /// The position the games will start from: the field's FEN, or the
  /// standard start when the field is empty.
  String get _effectiveFen {
    final text = _fen.text.trim();
    return text.isEmpty ? kStandardStartFen : text;
  }

  void _validateFen() {
    String? error;
    if (_fen.text.trim().isNotEmpty) {
      try {
        Chess.fromSetup(Setup.parseFen(_fen.text.trim()));
      } catch (e) {
        error = _describeFenError(e);
      }
    }
    // Rebuild unconditionally: the preview board and the footer summary read
    // the FEN text directly, so an edit that stays valid must still repaint.
    setState(() => _fenError = error);
  }

  /// Put [fen] in the field — or clear it when it is the standard start, so
  /// the field only ever shows a position that differs from the default.
  void _setFen(String fen) {
    _fen.text = normalizeFen(fen) == normalizeFen(kStandardStartFen) ? '' : fen;
  }

  /// Open the full board editor seeded with the position in play.
  Future<void> _editBoard() async {
    final position = await BoardEditorDialog.show(
      context,
      initialFen: _fenError == null ? _effectiveFen : null,
      actionLabel: 'Use this position',
    );
    if (position != null) _setFen(position.fen);
  }

  static String _describeFenError(Object error) {
    final text = '$error';
    if (text.contains('PositionSetupException')) {
      return 'That FEN parses but is not a legal position '
          '(${text.split(':').last.trim()}).';
    }
    return 'Could not read that FEN.';
  }

  /// The app's board is worth offering only when it shows something other
  /// than the position already in play.
  bool get _canUseBoardPosition =>
      normalizeFen(widget.boardFen) != normalizeFen(_effectiveFen);

  List<EngineSpec> get _selectedSpecs => [
    for (final id in _participants)
      widget.engines.firstWhere(
        (e) => e.id == id,
        orElse: () => widget.engines.first,
      ),
  ];

  /// Two participants sharing a name would produce a crosstable nobody could
  /// read, so repeats are suffixed the way cutechess does it.
  List<EngineSpec> get _namedSpecs {
    final counts = <String, int>{};
    final seen = <String, int>{};
    for (final spec in _selectedSpecs) {
      counts[spec.name] = (counts[spec.name] ?? 0) + 1;
    }
    return [
      for (final spec in _selectedSpecs)
        if ((counts[spec.name] ?? 0) > 1)
          spec.copyWith(
            name:
                '${spec.name} #${seen[spec.name] = (seen[spec.name] ?? 0) + 1}',
          )
        else
          spec,
    ];
  }

  bool get _canStart => _fenError == null && _participants.length >= 2;

  @override
  Widget build(BuildContext context) {
    final specs = _namedSpecs;
    final config = _buildConfig(specs);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
          child: Row(
            children: [
              const Text('New tournament', style: AppTextStyles.title),
              const Spacer(),
              Tooltip(
                message:
                    'Which engines play, the exact clock, games at once, '
                    'adjudication.',
                child: TextButton.icon(
                  key: const ValueKey('new-tournament-advanced'),
                  onPressed: () =>
                      setState(() => _showAdvanced = !_showAdvanced),
                  icon: Icon(
                    _showAdvanced ? Icons.expand_less : Icons.tune,
                    size: 16,
                  ),
                  label: const Text('Advanced'),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.divider),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildBasics(),
                if (_showAdvanced) ...[
                  const SizedBox(height: 22),
                  const Divider(height: 1, color: AppColors.divider),
                  const SizedBox(height: 18),
                  _buildAdvanced(config),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: AppColors.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _canStart
                      ? _summary(specs, config)
                      : (_fenError ?? 'Pick at least two engines.'),
                  style: AppTextStyles.hint.copyWith(
                    color: _canStart
                        ? AppColors.onSurfaceMuted
                        : AppColors.danger,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('new-tournament-start'),
                onPressed: _canStart
                    ? () => Navigator.of(context).pop(config)
                    : null,
                child: const Text('Start'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  TournamentConfig _buildConfig(List<EngineSpec> specs) => TournamentConfig(
    name: _name.text.trim().isEmpty ? 'Engine match' : _name.text.trim(),
    engines: specs,
    startFen: _effectiveFen,
    openingLabel: _opening.text.trim(),
    timeControl: _timeControl,
    gamesPerPairing: _gamesPerPairing,
    alternateColors: _alternateColors,
    format: _format,
    concurrency: _concurrency,
    annotateMoves: _annotateMoves,
    adjudication: _adjudication,
  );

  /// "Stockfish against itself · 10 games · 2 s / move · ≈ 47 min".
  String _summary(List<EngineSpec> specs, TournamentConfig config) {
    final selected = _selectedSpecs;
    final who = switch (selected.length) {
      2 when selected[0].id == selected[1].id =>
        '${selected[0].name} against itself',
      2 => '${specs[0].name} vs ${specs[1].name}',
      _ => '${specs.length} engines',
    };
    return '$who · ${config.totalGames} games · '
        '${config.timeControl.label} · ${_estimate(config)}';
  }

  // ── Basics: what you came here to change ────────────────────────────────

  Widget _buildBasics() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreview(),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('new-tournament-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('new-tournament-fen'),
                controller: _fen,
                style: AppTextStyles.body.copyWith(
                  fontFamily: AppTextStyles.monoFamily,
                ),
                decoration: InputDecoration(
                  labelText: 'Start position',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  hintText: 'Standard start — paste a FEN to change',
                  hintStyle: AppTextStyles.hint,
                  errorText: _fenError,
                  errorMaxLines: 3,
                  suffixIcon: _fen.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Back to the standard start',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => _fen.clear(),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    key: const ValueKey('new-tournament-edit-board'),
                    onPressed: _editBoard,
                    child: const Text('Edit board…'),
                  ),
                  if (_canUseBoardPosition)
                    TextButton(
                      onPressed: () => _setFen(widget.boardFen),
                      child: const Text('Use the board position'),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: _NumberField(
                      key: const ValueKey('new-tournament-games'),
                      label: 'Games',
                      value: _gamesPerPairing,
                      min: 1,
                      max: 1000,
                      onChanged: (v) => setState(() => _gamesPerPairing = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _buildTimePreset()),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (_fenError != null) {
      return Container(
        width: _boardSize,
        height: _boardSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceInset,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(
          Icons.report_gmailerrorred_outlined,
          color: AppColors.danger,
        ),
      );
    }
    return Tooltip(
      message: 'Edit this position',
      child: InkWell(
        onTap: _editBoard,
        child: StaticBoardThumbnail(
          fen: _effectiveFen,
          size: _boardSize,
          flipped: false,
        ),
      ),
    );
  }

  Widget _buildTimePreset() {
    final presetIndex = kTimeControlPresets.indexWhere(
      (p) => p.tc.label == _timeControl.label,
    );
    return DropdownButtonFormField<int>(
      key: const ValueKey('new-tournament-time'),
      initialValue: presetIndex < 0 ? null : presetIndex,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Time', isDense: true),
      hint: Text(_timeControl.label),
      items: [
        for (var i = 0; i < kTimeControlPresets.length; i++)
          DropdownMenuItem(
            value: i,
            child: Text(
              kTimeControlPresets[i].label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (index) {
        if (index == null) return;
        setState(() => _timeControl = kTimeControlPresets[index].tc);
      },
    );
  }

  // ── Advanced: everything with a default worth keeping ───────────────────

  Widget _buildAdvanced(TournamentConfig config) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Engines',
          trailing: TextButton(
            onPressed: widget.onManageEngines,
            child: const Text('Manage engines…'),
          ),
          child: _buildParticipants(),
        ),
        _Section(title: 'Time control', child: _buildTimeControlDetail()),
        _Section(title: 'Games', child: _buildSchedule(config)),
        _Section(
          title: 'Adjudication',
          subtitle:
              'When to stop a game the engines will not finish on their own.',
          showDivider: false,
          child: _buildAdjudication(),
        ),
      ],
    );
  }

  Widget _buildParticipants() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _participants.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text('${i + 1}', style: AppTextStyles.muted),
                ),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _participants[i],
                    isDense: true,
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      for (final engine in widget.engines)
                        DropdownMenuItem(
                          value: engine.id,
                          child: Text(
                            engine.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _participants[i] = value);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _participants.length <= 2
                      ? null
                      : () => setState(() => _participants.removeAt(i)),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                setState(() => _participants.add(widget.engines.first.id)),
            child: const Text('Add engine'),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeControlDetail() {
    switch (_timeControl.kind) {
      case TimeControlKind.movetime:
        return _NumberField(
          label: 'Milliseconds per move',
          value: _timeControl.movetimeMs,
          min: 10,
          max: 600000,
          onChanged: (v) => setState(
            () => _timeControl = _timeControl.copyWith(movetimeMs: v),
          ),
        );
      case TimeControlKind.incremental:
        return Row(
          children: [
            Expanded(
              child: _NumberField(
                label: 'Base (ms)',
                value: _timeControl.baseMs,
                min: 100,
                max: 7200000,
                onChanged: (v) => setState(
                  () => _timeControl = _timeControl.copyWith(baseMs: v),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _NumberField(
                label: 'Increment (ms)',
                value: _timeControl.incrementMs,
                min: 0,
                max: 60000,
                onChanged: (v) => setState(
                  () => _timeControl = _timeControl.copyWith(incrementMs: v),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _NumberField(
                label: 'Moves/session',
                value: _timeControl.movesPerSession ?? 0,
                min: 0,
                max: 200,
                helper: '0 = sudden death',
                onChanged: (v) => setState(
                  () => _timeControl = _timeControl.copyWith(
                    movesPerSession: v == 0 ? null : v,
                  ),
                ),
              ),
            ),
          ],
        );
      case TimeControlKind.fixedDepth:
        return _NumberField(
          label: 'Depth',
          value: _timeControl.depth,
          min: 1,
          max: 60,
          onChanged: (v) =>
              setState(() => _timeControl = _timeControl.copyWith(depth: v)),
        );
      case TimeControlKind.fixedNodes:
        return _NumberField(
          label: 'Nodes',
          value: _timeControl.nodes,
          min: 1000,
          max: 1000000000,
          onChanged: (v) =>
              setState(() => _timeControl = _timeControl.copyWith(nodes: v)),
        );
    }
  }

  Widget _buildSchedule(TournamentConfig config) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_participants.length > 2) ...[
          SegmentedButton<TournamentFormat>(
            segments: [
              for (final format in TournamentFormat.values)
                ButtonSegment(value: format, label: Text(format.label)),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _NumberField(
                label: 'Games at once',
                value: _concurrency,
                min: 1,
                max: getLogicalCores(),
                helper: 'One is fairest',
                onChanged: (v) => setState(() => _concurrency = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _opening,
                decoration: const InputDecoration(
                  labelText: 'Opening label',
                  isDense: true,
                  helperText: 'Written to the PGN Opening tag.',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _alternateColors,
          onChanged: (v) => setState(() => _alternateColors = v ?? true),
          title: const Text('Alternate colours', style: AppTextStyles.body),
          subtitle: Text(
            'Each pairing plays ${config.gamesPerPairing} games with the '
            'colours swapping every game.',
            style: AppTextStyles.hint,
          ),
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _annotateMoves,
          onChanged: (v) => setState(() => _annotateMoves = v ?? false),
          title: const Text(
            'Annotate every move with the engine\'s eval',
            style: AppTextStyles.body,
          ),
          subtitle: const Text(
            'Writes {+0.31/24 2.001s} after each move — what engine-testing '
            'tools read, and what makes the game hard to follow in the viewer.',
            style: AppTextStyles.hint,
          ),
        ),
      ],
    );
  }

  Widget _buildAdjudication() {
    final rules = _adjudication;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: rules.drawEnabled,
          onChanged: (v) => setState(
            () => _adjudication = rules.copyWith(drawEnabled: v ?? true),
          ),
          title: const Text(
            'Call level games a draw',
            style: AppTextStyles.body,
          ),
        ),
        if (rules.drawEnabled)
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'After move',
                  value: rules.drawMoveNumber,
                  min: 1,
                  max: 300,
                  onChanged: (v) => setState(
                    () => _adjudication = rules.copyWith(drawMoveNumber: v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  label: 'For N moves',
                  value: rules.drawMoveCount,
                  min: 1,
                  max: 100,
                  onChanged: (v) => setState(
                    () => _adjudication = rules.copyWith(drawMoveCount: v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  label: 'Within (cp)',
                  value: rules.drawScoreCp,
                  min: 0,
                  max: 200,
                  onChanged: (v) => setState(
                    () => _adjudication = rules.copyWith(drawScoreCp: v),
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: 6),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: rules.resignEnabled,
          onChanged: (v) => setState(
            () => _adjudication = rules.copyWith(resignEnabled: v ?? true),
          ),
          title: const Text('Resign lost games', style: AppTextStyles.body),
        ),
        if (rules.resignEnabled)
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'For N moves',
                  value: rules.resignMoveCount,
                  min: 1,
                  max: 50,
                  onChanged: (v) => setState(
                    () => _adjudication = rules.copyWith(resignMoveCount: v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  label: 'Below (cp)',
                  value: rules.resignScoreCp,
                  min: 100,
                  max: 5000,
                  onChanged: (v) => setState(
                    () => _adjudication = rules.copyWith(resignScoreCp: v),
                  ),
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 12),
                  controlAffinity: ListTileControlAffinity.leading,
                  value: rules.twoSidedResign,
                  onChanged: (v) => setState(
                    () => _adjudication = rules.copyWith(
                      twoSidedResign: v ?? true,
                    ),
                  ),
                  title: const Text('Both agree', style: AppTextStyles.hint),
                ),
              ),
            ],
          ),
        const SizedBox(height: 6),
        _NumberField(
          label: 'Stop after N moves',
          value: rules.maxMoves,
          min: 20,
          max: 2000,
          helper: 'Filed as a draw.',
          onChanged: (v) =>
              setState(() => _adjudication = rules.copyWith(maxMoves: v)),
        ),
      ],
    );
  }

  /// Rough wall-clock estimate, so a 40-minute match is not a surprise.
  String _estimate(TournamentConfig config) {
    final tc = config.timeControl;
    final perGameSeconds = switch (tc.kind) {
      // ~70 moves a game is the usual figure; adjudication cuts most short.
      TimeControlKind.movetime => tc.movetimeMs * 140 / 1000,
      TimeControlKind.incremental =>
        (tc.baseMs + tc.incrementMs * 70) * 2 / 1000,
      _ => 0.0,
    };
    if (perGameSeconds == 0) return 'duration depends on the engines';
    final total =
        perGameSeconds * config.totalGames / config.concurrency.clamp(1, 64);
    if (total < 90) return '≈ ${total.round()} s';
    if (total < 5400) return '≈ ${(total / 60).round()} min';
    return '≈ ${(total / 3600).toStringAsFixed(1)} h';
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.showDivider = true,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(title.toUpperCase(), style: AppTextStyles.eyebrow),
            const Spacer(),
            ?trailing,
          ],
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!, style: AppTextStyles.hint),
          ),
        const SizedBox(height: 10),
        child,
        if (showDivider) ...[
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.helper,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final String? helper;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.value}',
  );

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && '${widget.value}' != _controller.text) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        isDense: true,
      ),
      onChanged: (text) {
        final parsed = int.tryParse(text);
        if (parsed == null) return;
        widget.onChanged(parsed.clamp(widget.min, widget.max));
      },
    );
  }
}
