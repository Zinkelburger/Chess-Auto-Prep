/// Polished analysis settings: opponent model, Lichess DB, engine, expectimax.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/engine_settings.dart';
import '../../theme/app_colors.dart';
import '../../services/coverage_service.dart';
import '../lichess_db_selector.dart';

/// Opens a wide dialog with all PGN-tab analysis settings.
Future<void> showAnalysisSettingsSheet(BuildContext context) async {
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return;

  final size = MediaQuery.sizeOf(context);
  final width = (size.width - 32).clamp(320.0, 1180.0);
  final height = (size.height - 32).clamp(400.0, 880.0);

  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: width,
        height: height,
        child: const _AnalysisSettingsSheet(),
      ),
    ),
  );
}

class _AnalysisSettingsSheet extends StatefulWidget {
  const _AnalysisSettingsSheet();

  @override
  State<_AnalysisSettingsSheet> createState() => _AnalysisSettingsSheetState();
}

class _AnalysisSettingsSheetState extends State<_AnalysisSettingsSheet> {
  final _settings = EngineSettings();
  final _probStartCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _probStartCtrl.text = _settings.probabilityStartMoves;
  }

  @override
  void dispose() {
    _probStartCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          children: [
            _buildTitleBar(theme),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 760) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildLeftColumn(),
                          const SizedBox(height: 16),
                          const Divider(height: 1, color: AppColors.divider),
                          const SizedBox(height: 16),
                          _buildOpponentColumn(),
                          const SizedBox(height: 16),
                          const Divider(height: 1, color: AppColors.divider),
                          const SizedBox(height: 16),
                          _buildEngineColumn(),
                        ],
                      ),
                    );
                  }

                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 2, child: _buildLeftColumn()),
                          const VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: AppColors.divider),
                          Expanded(flex: 3, child: _buildOpponentColumn()),
                          const VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: AppColors.divider),
                          Expanded(flex: 2, child: _buildEngineColumn()),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
      child: Row(
        children: [
          Icon(Icons.tune, color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 10),
          Text(
            'Analysis settings',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              _settings.resetToDefaults();
              _probStartCtrl.text = _settings.probabilityStartMoves;
            },
            child: const Text('Reset'),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // ── Column 1: Analysis panels ───────────────────────────────────────────

  Widget _buildLeftColumn() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSection(
            icon: Icons.view_column,
            title: 'Analysis panels',
            subtitle: 'Live analysis shown above the PGN notation. '
                'You can also tap a column header in the move table '
                'to dim it without hiding it.',
            showDivider: false,
            child: Column(
              children: [
                _SwitchRow(
                  label: 'Stockfish PV',
                  tooltip:
                      'Show the Stockfish principal variation panel — '
                      'top engine moves, eval, and continuation for the '
                      'current board position.',
                  value: _settings.showEngineDock,
                  onChanged: (v) => _settings.showEngineDock = v,
                ),
                _SwitchRow(
                  label: 'Expectimax PV',
                  tooltip:
                      'Show the Expectimax panel — best practical lines '
                      'that account for likely human opponent replies '
                      '(from the repertoire tree or computed on the fly).',
                  value: _settings.showExpectimaxDock,
                  onChanged: (v) => _settings.showExpectimaxDock = v,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Column 2: Opponent model + cumulative probability ──────────────────

  Widget _buildOpponentColumn() {
    final database = _settings.explorerUseMasters
        ? LichessDatabase.masters
        : LichessDatabase.lichess;
    final speeds = _settings.explorerSpeedSet;
    final ratings = _settings.explorerRatingSet;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSection(
            icon: Icons.people,
            title: 'Opponent model',
            subtitle:
                'How the app predicts what your opponent will play. '
                'Used in the move table (DB % / Maia % columns), '
                'expectimax evaluation, and difficulty scores.',
            showDivider: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LabeledDropdown<String>(
                  label: 'Prediction source',
                  tooltip:
                      'Maia: a neural net trained on human games — '
                      'predicts what a player of the chosen ELO would '
                      'actually play.\n\n'
                      'Lichess DB: raw move frequencies from the Lichess '
                      'opening explorer (millions of real games).\n\n'
                      'Maia + DB fallback: uses Maia predictions, but '
                      'when a move also appears in the database, blends '
                      'in the DB frequency for better coverage.',
                  value: _settings.opponentProbabilityMode,
                  items: const [
                    ('maia', 'Maia neural net'),
                    ('lichess', 'Lichess database frequencies'),
                    ('maia_lichess_fallback', 'Maia + DB fallback'),
                  ],
                  onChanged: (v) {
                    if (v != null) _settings.opponentProbabilityMode = v;
                  },
                ),
                const SizedBox(height: 8),
                _SwitchRow(
                  label: 'Show Maia % column',
                  tooltip:
                      'Show the Maia prediction column in the move table '
                      '(how likely a human of the chosen ELO plays each move).',
                  value: _settings.showMaia,
                  onChanged: (v) => _settings.showMaia = v,
                ),
                _SwitchRow(
                  label: 'Show DB % column',
                  tooltip:
                      'Show the Lichess database frequency column in the '
                      'move table (how often each move appears in real games).',
                  value: _settings.showProbability,
                  onChanged: (v) => _settings.showProbability = v,
                ),
                if (_settings.fetchLichessForOpponent) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: AppColors.divider),
                  const SizedBox(height: 8),
                  LichessDbSelector(
                    database: database,
                    onDatabaseChanged: (db) => _settings.explorerDatabase =
                        db == LichessDatabase.masters ? 'masters' : 'lichess',
                    selectedSpeeds: speeds,
                    onSpeedsChanged: _settings.setExplorerSpeedSet,
                    selectedRatings: ratings,
                    onRatingsChanged: _settings.setExplorerRatingSet,
                  ),
                ],
              ],
            ),
          ),
          _SettingsSection(
            icon: Icons.timeline,
            title: 'Cumulative line probability',
            subtitle:
                'Shown in the footer below the move table. '
                'Multiplies opponent reply probabilities along the current '
                'line to estimate how likely you are to reach this position '
                'in a real game.',
            showDivider: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TextFieldRow(
                  label: 'Starting position (moves)',
                  tooltip:
                      'If your repertoire starts after some opening moves '
                      '(e.g. "1. e4 e5 2. Nf3"), enter them here. The '
                      'cumulative % will start at 100% from this position '
                      'rather than from the initial position.\n\n'
                      'Leave empty to calculate from the very first move.',
                  controller: _probStartCtrl,
                  onSubmitted: (v) =>
                      _settings.probabilityStartMoves = v.trim(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Column 3: Engine tuning ────────────────────────────────────────────

  Widget _buildEngineColumn() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSection(
            icon: Icons.bolt,
            title: 'Stockfish engine',
            subtitle:
                'Controls the Stockfish analysis that powers the eval bar, '
                'move rankings, and difficulty scores.',
            showDivider: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SwitchRow(
                  label: 'Enable Stockfish',
                  tooltip:
                      'Run Stockfish in the background to evaluate moves. '
                      'Disabling saves CPU but removes eval/difficulty data.',
                  value: _settings.showStockfish,
                  onChanged: (v) => _settings.showStockfish = v,
                ),
                const SizedBox(height: 4),
                _IntFieldGrid(fields: [
                  _IntFieldSpec(
                    label: 'Depth',
                    tooltip:
                        'Search depth per position. Higher = more accurate '
                        'but slower. 15 is a good default.',
                    value: _settings.depth,
                    min: 1,
                    max: 40,
                    onChanged: (v) => _settings.depth = v,
                  ),
                  _IntFieldSpec(
                    label: 'MultiPV',
                    tooltip:
                        'How many top moves Stockfish evaluates in parallel. '
                        'Higher finds more candidate moves but is slower.',
                    value: _settings.multiPv,
                    min: 1,
                    max: 10,
                    onChanged: (v) => _settings.multiPv = v,
                  ),
                  _IntFieldSpec(
                    label: 'Workers',
                    tooltip:
                        'Parallel Stockfish processes. More = faster analysis '
                        'but uses more CPU. Max ${EngineSettings.systemCores} '
                        'on this machine.',
                    value: _settings.workers,
                    min: 1,
                    max: EngineSettings.systemCores,
                    onChanged: (v) => _settings.workers = v,
                  ),
                ]),
              ],
            ),
          ),
          _SettingsSection(
            icon: Icons.analytics,
            title: 'Expectimax search',
            subtitle:
                'Expectimax looks ahead several moves, weighting each '
                'opponent reply by how likely a human would play it '
                '(via the opponent model above). The result is a '
                '"practical" eval that reflects real-game outcomes.',
            showDivider: false,
            child: _IntFieldGrid(fields: [
              _IntFieldSpec(
                label: 'Maia ELO',
                tooltip:
                    'The skill level of the simulated opponent. '
                    'Higher ELO = stronger, more accurate replies.',
                value: _settings.maiaElo,
                min: 600,
                max: 2400,
                step: 100,
                onChanged: (v) => _settings.maiaElo = v,
              ),
              _IntFieldSpec(
                label: 'OTF depth',
                tooltip:
                    'On-the-fly search depth (plies) for positions '
                    'not already in the repertoire tree. Deeper = more '
                    'accurate but slower.',
                value: _settings.onTheFlyMaxDepth,
                min: 1,
                max: 12,
                onChanged: (v) => _settings.onTheFlyMaxDepth = v,
              ),
              _IntFieldSpec(
                label: 'Eval depth',
                tooltip:
                    'Stockfish depth used to evaluate leaf positions '
                    'in the expectimax tree.',
                value: _settings.expectimaxEvalDepth,
                min: 6,
                max: 20,
                onChanged: (v) => _settings.expectimaxEvalDepth = v,
              ),
              _IntFieldSpec(
                label: 'Our MultiPV',
                tooltip:
                    'How many candidate moves to consider for our side '
                    'at each node in the expectimax tree.',
                value: _settings.expectimaxOurMultipv,
                min: 1,
                max: 8,
                onChanged: (v) => _settings.expectimaxOurMultipv = v,
              ),
              _IntFieldSpec(
                label: 'Max loss cp',
                tooltip:
                    'Prune opponent moves that lose more than this many '
                    'centipawns vs the best move. Keeps the search '
                    'focused on plausible replies.',
                value: _settings.expectimaxMaxEvalLoss,
                min: 20,
                max: 300,
                step: 10,
                onChanged: (v) => _settings.expectimaxMaxEvalLoss = v,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Reusable building blocks
// ═══════════════════════════════════════════════════════════════════════════════

class _SettingsSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final bool showDivider;

  const _SettingsSection({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.child,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 17, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 10),
        child,
        if (showDivider) ...[
          const SizedBox(height: 16),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

// ── Integer stepper ─────────────────────────────────────────────────────────

class _IntFieldSpec {
  final String label;
  final String? tooltip;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  const _IntFieldSpec({
    required this.label,
    this.tooltip,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    required this.onChanged,
  });
}

class _IntFieldGrid extends StatelessWidget {
  final List<_IntFieldSpec> fields;
  const _IntFieldGrid({required this.fields});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 280) {
          return Column(
            children: [for (final f in fields) _CompactIntField(spec: f)],
          );
        }
        final half = (fields.length / 2).ceil();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(children: [
                for (final f in fields.sublist(0, half))
                  _CompactIntField(spec: f),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(children: [
                for (final f in fields.sublist(half))
                  _CompactIntField(spec: f),
              ]),
            ),
          ],
        );
      },
    );
  }
}

class _CompactIntField extends StatefulWidget {
  final _IntFieldSpec spec;
  const _CompactIntField({required this.spec});

  @override
  State<_CompactIntField> createState() => _CompactIntFieldState();
}

class _CompactIntFieldState extends State<_CompactIntField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.spec.value}');
  }

  @override
  void didUpdateWidget(_CompactIntField old) {
    super.didUpdateWidget(old);
    if (old.spec.value != widget.spec.value && !_ctrl.text.contains('.')) {
      final sel = _ctrl.selection;
      _ctrl.text = '${widget.spec.value}';
      // Restore cursor if it was inside the field.
      if (sel.isValid && sel.end <= _ctrl.text.length) {
        _ctrl.selection = sel;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_ctrl.text);
    if (n != null) {
      widget.spec.onChanged(n.clamp(widget.spec.min, widget.spec.max));
    } else {
      _ctrl.text = '${widget.spec.value}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final field = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(spec.label, style: const TextStyle(fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: spec.value > spec.min
                ? () => spec.onChanged(
                      (spec.value - spec.step).clamp(spec.min, spec.max),
                    )
                : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          SizedBox(
            width: 40,
            child: TextField(
              controller: _ctrl,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(vertical: 6),
              ),
              onSubmitted: (_) => _submit(),
              onEditingComplete: _submit,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: spec.value < spec.max
                ? () => spec.onChanged(
                      (spec.value + spec.step).clamp(spec.min, spec.max),
                    )
                : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
    if (spec.tooltip == null) return field;
    return Tooltip(message: spec.tooltip!, child: field);
  }
}

// ── Toggle row ──────────────────────────────────────────────────────────────

class _SwitchRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    this.tooltip,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip!, child: row);
  }
}

// ── Dropdown ────────────────────────────────────────────────────────────────

class _LabeledDropdown<T> extends StatelessWidget {
  final String label;
  final String? tooltip;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T?> onChanged;

  const _LabeledDropdown({
    required this.label,
    this.tooltip,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final field = DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      isDense: true,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12),
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      items: items
          .map((e) => DropdownMenuItem(value: e.$1, child: Text(e.$2)))
          .toList(),
      onChanged: onChanged,
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip!, child: field);
  }
}

// ── Text field ──────────────────────────────────────────────────────────────

class _TextFieldRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;

  const _TextFieldRow({
    required this.label,
    this.tooltip,
    required this.controller,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onSubmitted: onSubmitted,
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip!, child: field);
  }
}
