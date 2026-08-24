/// Set up a match or a tournament.
///
/// Defaults are chosen to be the ones you would pick anyway: the bundled
/// Stockfish against itself, two seconds a move, ten games with the colours
/// alternating, one game at a time, and the adjudication rules that stop
/// two equal engines shuffling a dead position for two hundred moves.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../constants/chess_constants.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
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
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 700),
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
  final _name = TextEditingController(text: 'Engine match');
  final _opening = TextEditingController();
  late final TextEditingController _fen = TextEditingController(
    text: kStandardStartFen,
  );

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

  void _validateFen() {
    final text = _fen.text.trim();
    String? error;
    if (text.isEmpty) {
      error = 'Enter a FEN, or use the standard starting position.';
    } else {
      try {
        Chess.fromSetup(Setup.parseFen(text));
      } catch (e) {
        error = _describeFenError(e);
      }
    }
    // Rebuild unconditionally: the preview board and the footer summary read
    // the FEN text directly, so an edit that stays valid must still repaint.
    setState(() => _fenError = error);
  }

  /// Open the full board editor seeded with whatever FEN is in the field.
  Future<void> _editBoard() async {
    final position = await BoardEditorDialog.show(
      context,
      initialFen: _fenError == null ? _fen.text.trim() : null,
      actionLabel: 'Use this position',
    );
    if (position != null) _fen.text = position.fen;
  }

  static String _describeFenError(Object error) {
    final text = '$error';
    if (text.contains('PositionSetupException')) {
      return 'That FEN parses but is not a legal position '
          '(${text.split(':').last.trim()}).';
    }
    return 'Could not read that FEN.';
  }

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
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              const Icon(
                Icons.emoji_events_outlined,
                size: 20,
                color: AppColors.onSurfaceSoft,
              ),
              const SizedBox(width: 10),
              const Text('New tournament', style: AppTextStyles.title),
              const Spacer(),
              TextButton.icon(
                onPressed: widget.onManageEngines,
                icon: const Icon(Icons.memory, size: 16),
                label: const Text('Engines…'),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.divider),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    helperText:
                        'Becomes the PGN Event tag and the folder on disk.',
                  ),
                ),
                const SizedBox(height: 18),
                _Section(
                  icon: Icons.groups_outlined,
                  title: 'Engines',
                  child: _buildParticipants(),
                ),
                _Section(
                  icon: Icons.grid_view,
                  title: 'Starting position',
                  child: _buildPosition(),
                ),
                _Section(
                  icon: Icons.timer_outlined,
                  title: 'Time control',
                  child: _buildTimeControl(),
                ),
                _Section(
                  icon: Icons.format_list_numbered,
                  title: 'Schedule',
                  child: _buildSchedule(config),
                ),
                _Section(
                  icon: Icons.gavel,
                  title: 'Adjudication',
                  subtitle:
                      'When to stop a game the engines will not finish on '
                      'their own.',
                  showDivider: false,
                  child: _buildAdjudication(),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: AppColors.divider),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _canStart
                      ? '${config.totalGames} games · '
                            '${config.timeControl.label} · '
                            '${_estimate(config)}'
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
              FilledButton.icon(
                onPressed: _canStart
                    ? () => Navigator.of(context).pop(config)
                    : null,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Start'),
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
    startFen: _fen.text.trim(),
    openingLabel: _opening.text.trim(),
    timeControl: _timeControl,
    gamesPerPairing: _gamesPerPairing,
    alternateColors: _alternateColors,
    format: _format,
    concurrency: _concurrency,
    annotateMoves: _annotateMoves,
    adjudication: _adjudication,
  );

  // ── Sections ─────────────────────────────────────────────────────────────

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
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _participants.add(widget.engines.first.id)),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add engine'),
          ),
        ),
      ],
    );
  }

  Widget _buildPosition() {
    final fen = _fen.text.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _fen,
                style: AppTextStyles.body.copyWith(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'FEN',
                  isDense: true,
                  errorText: _fenError,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _editBoard,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit board…'),
                  ),
                  TextButton(
                    onPressed: () => _fen.text = kStandardStartFen,
                    child: const Text('Standard start'),
                  ),
                  TextButton(
                    onPressed: () => _fen.text = widget.boardFen,
                    child: const Text('Current board position'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      final text = data?.text?.trim();
                      if (text != null && text.isNotEmpty) _fen.text = text;
                    },
                    child: const Text('Paste'),
                  ),
                  TextButton(
                    onPressed: fen.isEmpty
                        ? null
                        : () => copyToClipboard(
                            context,
                            fen,
                            successMessage: 'FEN copied.',
                          ),
                    child: const Text('Copy'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _opening,
                decoration: const InputDecoration(
                  labelText: 'Opening label (optional)',
                  isDense: true,
                  helperText: 'Written to the PGN Opening tag.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        if (_fenError == null)
          Tooltip(
            message: 'Edit this position',
            child: InkWell(
              onTap: _editBoard,
              child: StaticBoardThumbnail(fen: fen, size: 132),
            ),
          )
        else
          Container(
            width: 132,
            height: 132,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surfaceInset,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(
              Icons.report_gmailerrorred_outlined,
              color: AppColors.danger,
            ),
          ),
      ],
    );
  }

  Widget _buildTimeControl() {
    final presetIndex = kTimeControlPresets.indexWhere(
      (p) => p.tc.label == _timeControl.label,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          initialValue: presetIndex < 0 ? null : presetIndex,
          isDense: true,
          decoration: const InputDecoration(labelText: 'Preset', isDense: true),
          hint: Text(_timeControl.label),
          items: [
            for (var i = 0; i < kTimeControlPresets.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(kTimeControlPresets[i].label),
              ),
          ],
          onChanged: (index) {
            if (index == null) return;
            setState(() => _timeControl = kTimeControlPresets[index].tc);
          },
        ),
        const SizedBox(height: 10),
        _buildTimeControlDetail(),
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
          children: [
            Expanded(
              child: _NumberField(
                label: 'Games per pairing',
                value: _gamesPerPairing,
                min: 1,
                max: 1000,
                onChanged: (v) => setState(() => _gamesPerPairing = v),
              ),
            ),
            const SizedBox(width: 12),
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
    if (total < 90) return '≈ ${total.round()}s at most';
    if (total < 5400) return '≈ ${(total / 60).round()} min at most';
    return '≈ ${(total / 3600).toStringAsFixed(1)} h at most';
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppColors.onSurfaceDim),
            const SizedBox(width: 8),
            Text(title, style: AppTextStyles.bodyStrong),
          ],
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
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
