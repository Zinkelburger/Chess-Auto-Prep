/// Trick-hunt configuration dialog for Player Analysis.
///
/// Collects a [TrickHuntConfig] and pops with it; the host screen owns the
/// hunt lifecycle. Unlike Find Holes (which attacks what the file already
/// plays), Find Tricks searches for near-best moves and novelties for the
/// opposite side that score better in practice than the engine-best move.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../widgets/labeled_toggle.dart';
import '../services/trick_hunt_config.dart';

class TrickHuntConfigDialog extends StatefulWidget {
  /// Name of the analyzed player, for the framing text.
  final String playerName;

  /// Colour of the game tree being hunted (the displayed colour).
  final bool treeIsWhite;

  /// Settings from the previous hunt, if any, to prefill the fields.
  final TrickHuntConfig? initialConfig;

  const TrickHuntConfigDialog({
    super.key,
    required this.playerName,
    required this.treeIsWhite,
    this.initialConfig,
  });

  @override
  State<TrickHuntConfigDialog> createState() => _TrickHuntConfigDialogState();
}

class _TrickHuntConfigDialogState extends State<TrickHuntConfigDialog> {
  late final TextEditingController _discoveryDepthCtrl;
  late final TextEditingController _maiaEloCtrl;
  late final TextEditingController _probeBudgetCtrl;
  late final TextEditingController _probePlyCtrl;
  late final TextEditingController _maxPlyCtrl;
  late final TextEditingController _minReachPctCtrl;
  late final TextEditingController _maxDiscoveryCtrl;
  late final TextEditingController _windowCtrl;
  late final TextEditingController _maxPerNodeCtrl;
  late final TextEditingController _probeEvalDepthCtrl;
  late final TextEditingController _probeTimeoutCtrl;
  late final TextEditingController _minNetGainCtrl;

  late bool _useLichess;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initialConfig ?? const TrickHuntConfig();
    _useLichess = c.useLichessInProbes;
    _discoveryDepthCtrl = TextEditingController(text: '${c.discoveryDepth}');
    _maiaEloCtrl = TextEditingController(text: '${c.maiaElo}');
    _probeBudgetCtrl = TextEditingController(text: '${c.probeBudget}');
    _probePlyCtrl = TextEditingController(text: '${c.probePly}');
    _maxPlyCtrl = TextEditingController(text: '${c.maxPly}');
    _minReachPctCtrl = TextEditingController(
      text: _formatPercent(c.minReachProb * 100),
    );
    _maxDiscoveryCtrl = TextEditingController(text: '${c.maxDiscoveryNodes}');
    _windowCtrl = TextEditingController(text: '${c.candidateWindowCp}');
    _maxPerNodeCtrl = TextEditingController(text: '${c.maxCandidatesPerNode}');
    _probeEvalDepthCtrl = TextEditingController(text: '${c.probeEvalDepth}');
    _probeTimeoutCtrl = TextEditingController(text: '${c.probeTimeoutSeconds}');
    _minNetGainCtrl = TextEditingController(text: '${c.minNetGainCp}');
  }

  static String _formatPercent(double pct) {
    final asInt = pct.truncateToDouble() == pct;
    return asInt ? pct.toStringAsFixed(0) : '$pct';
  }

  @override
  void dispose() {
    _discoveryDepthCtrl.dispose();
    _maiaEloCtrl.dispose();
    _probeBudgetCtrl.dispose();
    _probePlyCtrl.dispose();
    _maxPlyCtrl.dispose();
    _minReachPctCtrl.dispose();
    _maxDiscoveryCtrl.dispose();
    _windowCtrl.dispose();
    _maxPerNodeCtrl.dispose();
    _probeEvalDepthCtrl.dispose();
    _probeTimeoutCtrl.dispose();
    _minNetGainCtrl.dispose();
    super.dispose();
  }

  TrickHuntConfig _buildConfig() {
    final defaults = widget.initialConfig ?? const TrickHuntConfig();
    final reachPct = double.tryParse(_minReachPctCtrl.text);
    return defaults.copyWith(
      discoveryDepth:
          int.tryParse(_discoveryDepthCtrl.text) ?? defaults.discoveryDepth,
      maiaElo: int.tryParse(_maiaEloCtrl.text) ?? defaults.maiaElo,
      probeBudget: int.tryParse(_probeBudgetCtrl.text) ?? defaults.probeBudget,
      probePly: int.tryParse(_probePlyCtrl.text) ?? defaults.probePly,
      maxPly: int.tryParse(_maxPlyCtrl.text) ?? defaults.maxPly,
      minReachProb: reachPct != null ? reachPct / 100 : defaults.minReachProb,
      maxDiscoveryNodes:
          int.tryParse(_maxDiscoveryCtrl.text) ?? defaults.maxDiscoveryNodes,
      candidateWindowCp:
          int.tryParse(_windowCtrl.text) ?? defaults.candidateWindowCp,
      maxCandidatesPerNode:
          int.tryParse(_maxPerNodeCtrl.text) ?? defaults.maxCandidatesPerNode,
      probeEvalDepth:
          int.tryParse(_probeEvalDepthCtrl.text) ?? defaults.probeEvalDepth,
      probeTimeoutSeconds:
          int.tryParse(_probeTimeoutCtrl.text) ?? defaults.probeTimeoutSeconds,
      minNetGainCp: int.tryParse(_minNetGainCtrl.text) ?? defaults.minNetGainCp,
      useLichessInProbes: _useLichess,
    );
  }

  @override
  Widget build(BuildContext context) {
    final treeColor = widget.treeIsWhite ? 'White' : 'Black';
    final tricksterColor = widget.treeIsWhite ? 'Black' : 'White';

    return AlertDialog(
      title: const Text('Find Tricks'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Find Tricks plays the $tricksterColor side of '
                '${widget.playerName}\'s $treeColor games and hunts for '
                'moves that are close to engine-best but poisonous in '
                'practice — including novelties the games never faced:',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              const Text(
                '• At each frequently reached position, several near-best '
                'engine moves are considered, not just the top one\n'
                '• Each candidate is probed a few half-moves deep with a '
                'Maia expectimax search of the likely replies\n'
                '• A move is reported when its practical value beats even '
                'the best move\'s raw eval — the expected mistakes outweigh '
                'what the move concedes',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 6),
              const Text(
                'Results are ranked by reach probability × net gain, so you '
                'get a short list of killer tricks — not every playable '
                'sideline.',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
              ),
              const SizedBox(height: 16),

              // Key knobs
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField(
                    _discoveryDepthCtrl,
                    'Engine depth',
                    tooltip:
                        'Stockfish search depth when discovering candidate '
                        'moves at each position.',
                  ),
                  _numField(
                    _maiaEloCtrl,
                    'Maia rating',
                    tooltip:
                        'Playing strength of the Maia human model used for '
                        'the opponent\'s replies in probes.',
                  ),
                  _numField(
                    _probeBudgetCtrl,
                    'Moves to probe',
                    tooltip:
                        'Total number of candidate moves that get the deep '
                        'expectimax probe, best prospects first.',
                  ),
                  _numField(
                    _probePlyCtrl,
                    'Probe depth (half-moves)',
                    tooltip:
                        'How far past each candidate move the expectimax '
                        'probe looks, in half-moves.',
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // More thresholds (collapsed by default)
              InkWell(
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Row(
                  children: [
                    Icon(
                      _showAdvanced ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: AppColors.onSurfaceMuted,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'More thresholds',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _numField(
                      _maxPlyCtrl,
                      'Max depth (half-moves)',
                      tooltip:
                          'How far into each line the hunt walks, counted '
                          'in half-moves from the start position.',
                    ),
                    _numField(
                      _minReachPctCtrl,
                      'Min reach probability (%)',
                      tooltip:
                          'Positions less likely than this to be reached '
                          'are skipped entirely.',
                    ),
                    _numField(
                      _maxDiscoveryCtrl,
                      'Positions to search',
                      tooltip:
                          'Cap on positions that get the engine candidate '
                          'search, most reachable first.',
                    ),
                    _numField(
                      _windowCtrl,
                      'Candidate window (centipawns)',
                      tooltip:
                          'A candidate may concede at most this many '
                          'centipawns versus the engine best move.',
                    ),
                    _numField(
                      _maxPerNodeCtrl,
                      'Candidates per position',
                      tooltip:
                          'At most this many candidates per position enter '
                          'the probe pool.',
                    ),
                    _numField(
                      _probeEvalDepthCtrl,
                      'Probe eval depth',
                      tooltip:
                          'Stockfish depth for position evals inside the '
                          'expectimax probes.',
                    ),
                    _numField(
                      _probeTimeoutCtrl,
                      'Probe time limit (seconds)',
                      tooltip: 'Wall-clock budget for each single probe.',
                    ),
                    _numField(
                      _minNetGainCtrl,
                      'Min net gain (centipawns)',
                      tooltip:
                          'Minimum practical gain over the engine-best '
                          'move\'s raw eval for a trick to be reported.',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AppCheckbox(
                  label: 'Blend Lichess statistics into probes',
                  value: _useLichess,
                  onChanged: (v) => setState(() => _useLichess = v),
                  tooltip:
                      'Use Lichess Explorer move frequencies alongside Maia '
                      'for the opponent model while the probe is still in '
                      'book; Maia alone otherwise.',
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Needs the Maia human model. Probes run one at a time — '
                'this can take a while, and it keeps working while you '
                'browse.',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
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
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_buildConfig()),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Start Hunt'),
        ),
      ],
    );
  }

  Widget _numField(
    TextEditingController ctrl,
    String label, {
    String? tooltip,
  }) {
    final field = SizedBox(
      width: 220,
      child: TextField(
        controller: ctrl,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: TextInputType.number,
      ),
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip, child: field);
  }
}
