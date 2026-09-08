/// Hole-hunt configuration dialog for Player Analysis.
///
/// Collects a [HoleHuntConfig] and pops with it; the host screen owns the
/// hunt lifecycle. Unlike Analyze with Engine (raw Stockfish eval coloring),
/// this is an adversarial hunt from the opposite side: uncovered strong
/// moves, verified refutations, and Maia-probed tricks.
library;

import 'package:flutter/material.dart';

import '../../../services/maia/maia_factory.dart';
import '../../../theme/app_text_styles.dart';
import '../../audit/widgets/hunt_controls.dart';
import '../services/hole_hunt_config.dart';

class HoleHuntConfigDialog extends StatefulWidget {
  /// Name of the analyzed player, for the framing text.
  final String playerName;

  /// Colour of the game tree being hunted (the displayed colour).
  final bool treeIsWhite;

  /// Settings from the previous hunt, if any, to prefill the fields.
  final HoleHuntConfig? initialConfig;

  const HoleHuntConfigDialog({
    super.key,
    required this.playerName,
    required this.treeIsWhite,
    this.initialConfig,
  });

  @override
  State<HoleHuntConfigDialog> createState() => _HoleHuntConfigDialogState();
}

class _HoleHuntConfigDialogState extends State<HoleHuntConfigDialog> {
  late final TextEditingController _discoveryDepthCtrl;
  late final TextEditingController _maxPlyCtrl;
  late final TextEditingController _maiaEloCtrl;
  late final TextEditingController _probeBudgetCtrl;
  late final TextEditingController _strongWindowCtrl;
  late final TextEditingController _refutationCtrl;
  late final TextEditingController _verifyDepthCtrl;
  late final TextEditingController _windowCtrl;
  late final TextEditingController _probePlyCtrl;
  late final TextEditingController _probeEvalDepthCtrl;
  late final TextEditingController _minNetGainCtrl;

  bool _showAdvanced = false;

  /// The trick search is Maia expectimax; without the model its knobs do
  /// nothing, so they are hidden rather than shown disabled.
  bool get _canProbe => MaiaFactory.isAvailable;

  @override
  void initState() {
    super.initState();
    final c = widget.initialConfig ?? const HoleHuntConfig();
    _discoveryDepthCtrl = TextEditingController(text: '${c.discoveryDepth}');
    _maxPlyCtrl = TextEditingController(text: '${c.maxPly}');
    _maiaEloCtrl = TextEditingController(text: '${c.maiaElo}');
    _probeBudgetCtrl = TextEditingController(text: '${c.probeBudget}');
    _strongWindowCtrl = TextEditingController(text: '${c.strongMoveWindowCp}');
    _refutationCtrl = TextEditingController(text: '${c.refutationThresholdCp}');
    _verifyDepthCtrl = TextEditingController(text: '${c.verifyDepth}');
    _windowCtrl = TextEditingController(text: '${c.candidateWindowCp}');
    _probePlyCtrl = TextEditingController(text: '${c.probePly}');
    _probeEvalDepthCtrl = TextEditingController(text: '${c.probeEvalDepth}');
    _minNetGainCtrl = TextEditingController(text: '${c.minNetGainCp}');
  }

  @override
  void dispose() {
    _discoveryDepthCtrl.dispose();
    _maxPlyCtrl.dispose();
    _maiaEloCtrl.dispose();
    _probeBudgetCtrl.dispose();
    _strongWindowCtrl.dispose();
    _refutationCtrl.dispose();
    _verifyDepthCtrl.dispose();
    _windowCtrl.dispose();
    _probePlyCtrl.dispose();
    _probeEvalDepthCtrl.dispose();
    _minNetGainCtrl.dispose();
    super.dispose();
  }

  HoleHuntConfig _buildConfig() {
    final defaults = widget.initialConfig ?? const HoleHuntConfig();
    return defaults.copyWith(
      discoveryDepth:
          int.tryParse(_discoveryDepthCtrl.text) ?? defaults.discoveryDepth,
      maxPly: int.tryParse(_maxPlyCtrl.text) ?? defaults.maxPly,
      maiaElo: int.tryParse(_maiaEloCtrl.text) ?? defaults.maiaElo,
      probeBudget: _canProbe
          ? int.tryParse(_probeBudgetCtrl.text) ?? defaults.probeBudget
          : 0,
      strongMoveWindowCp:
          int.tryParse(_strongWindowCtrl.text) ?? defaults.strongMoveWindowCp,
      refutationThresholdCp:
          int.tryParse(_refutationCtrl.text) ?? defaults.refutationThresholdCp,
      verifyDepth: int.tryParse(_verifyDepthCtrl.text) ?? defaults.verifyDepth,
      candidateWindowCp:
          int.tryParse(_windowCtrl.text) ?? defaults.candidateWindowCp,
      probePly: int.tryParse(_probePlyCtrl.text) ?? defaults.probePly,
      probeEvalDepth:
          int.tryParse(_probeEvalDepthCtrl.text) ?? defaults.probeEvalDepth,
      minNetGainCp: int.tryParse(_minNetGainCtrl.text) ?? defaults.minNetGainCp,
    );
  }

  @override
  Widget build(BuildContext context) {
    final treeColor = widget.treeIsWhite ? 'White' : 'Black';
    final attackerColor = widget.treeIsWhite ? 'Black' : 'White';

    return AlertDialog(
      title: const Text('Find Holes'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Not the same as Analyze with Engine (that only scores '
                'positions by raw Stockfish eval). Find Holes attacks '
                '${widget.playerName}\'s $treeColor games from the '
                '$attackerColor side and looks for ways to beat the lines:',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                '• Uncovered strong moves — engine-best $attackerColor '
                'tries with no reply in the games\n'
                '• Refutations — $treeColor moves that lose after a '
                'verified Stockfish reply\n'
                '• Tricks — near-best $attackerColor moves and novelties '
                'that score better in practice than the engine move, '
                'because the likely replies run into trouble a few '
                'moves deeper',
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 6),
              const Text(
                'Results are ranked by reach probability × gain, so you '
                'get a short list of killer holes — not every bad eval.',
                style: AppTextStyles.caption,
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
                    _maxPlyCtrl,
                    'Max depth (half-moves)',
                    tooltip:
                        'How far into each line the hunt walks, counted in '
                        'half-moves from the start position.',
                  ),
                  if (_canProbe) ...[
                    _numField(
                      _maiaEloCtrl,
                      'Maia rating',
                      tooltip:
                          'Playing strength of the Maia human model used '
                          'for the opponent\'s replies in trick probes.',
                    ),
                    _numField(
                      _probeBudgetCtrl,
                      'Moves to probe',
                      tooltip:
                          'Total number of trick candidates that get the '
                          'deep expectimax probe, best prospects first. '
                          'Zero skips the trick search.',
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),

              DisclosureHeader(
                label: 'More thresholds',
                expanded: _showAdvanced,
                onToggle: () => setState(() => _showAdvanced = !_showAdvanced),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _numField(
                      _strongWindowCtrl,
                      'Strong-move window (centipawns)',
                      tooltip:
                          'An uncovered attacker move must be within this '
                          'many centipawns of the engine best to be flagged.',
                    ),
                    _numField(
                      _refutationCtrl,
                      'Refutation threshold (centipawns)',
                      tooltip:
                          'Eval loss versus the engine best move needed to '
                          'flag a repertoire move as refuted.',
                    ),
                    _numField(
                      _verifyDepthCtrl,
                      'Verification depth',
                      tooltip:
                          'Deeper single-line Stockfish check that confirms '
                          'a refutation before it is reported.',
                    ),
                    if (_canProbe) ...[
                      _numField(
                        _windowCtrl,
                        'Trick window (centipawns)',
                        tooltip:
                            'A trick candidate may concede at most this '
                            'many centipawns versus the engine best move.',
                      ),
                      _numField(
                        _probePlyCtrl,
                        'Probe depth (half-moves)',
                        tooltip:
                            'How far past each candidate move the '
                            'expectimax probe looks, in half-moves.',
                      ),
                      _numField(
                        _probeEvalDepthCtrl,
                        'Probe eval depth',
                        tooltip:
                            'Stockfish depth for position evals inside the '
                            'expectimax probes.',
                      ),
                      _numField(
                        _minNetGainCtrl,
                        'Min net gain (centipawns)',
                        tooltip:
                            'Minimum practical gain over the engine-best '
                            'move\'s raw eval for a trick to be reported.',
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text(
                _canProbe
                    ? 'Stockfish walks the tree first; the trick probes run '
                          'Maia expectimax afterwards. Can take a while — it '
                          'keeps working while you browse.'
                    : 'The Maia human model is not available on this '
                          'machine, so tricks are not searched. Can take a '
                          'while — it keeps working while you browse.',
                style: AppTextStyles.caption,
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
  }) => HuntNumberField(controller: ctrl, label: label, tooltip: tooltip);
}
