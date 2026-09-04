/// Hole-hunt configuration dialog for Player Analysis.
///
/// Collects a [HoleHuntConfig] and pops with it; the host screen owns the
/// hunt lifecycle. Unlike Analyze with Engine (raw Stockfish eval coloring),
/// this is an adversarial hunt from the opposite side: uncovered strong
/// moves, verified refutations, plus an end-of-line Maia expectimax pass
/// for practical traps.
library;

import 'package:flutter/material.dart';

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
  late final TextEditingController _trapLeavesCtrl;
  late final TextEditingController _strongWindowCtrl;
  late final TextEditingController _refutationCtrl;
  late final TextEditingController _verifyDepthCtrl;
  late final TextEditingController _trapPlyCtrl;
  late final TextEditingController _trapGapCtrl;

  /// True = "attack this player", false = "stress-test my own play".
  /// Framing only — the attacker is always the side opposite the tree.
  late bool _attackMode;

  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initialConfig ?? const HoleHuntConfig();
    _attackMode = c.attackerIsUser;
    _discoveryDepthCtrl = TextEditingController(text: '${c.discoveryDepth}');
    _maxPlyCtrl = TextEditingController(text: '${c.maxPly}');
    _maiaEloCtrl = TextEditingController(text: '${c.maiaElo}');
    _trapLeavesCtrl = TextEditingController(text: '${c.trapLeafCount}');
    _strongWindowCtrl = TextEditingController(text: '${c.strongMoveWindowCp}');
    _refutationCtrl = TextEditingController(text: '${c.refutationThresholdCp}');
    _verifyDepthCtrl = TextEditingController(text: '${c.verifyDepth}');
    _trapPlyCtrl = TextEditingController(text: '${c.trapSearchPly}');
    _trapGapCtrl = TextEditingController(text: '${c.practicalGapThresholdCp}');
  }

  @override
  void dispose() {
    _discoveryDepthCtrl.dispose();
    _maxPlyCtrl.dispose();
    _maiaEloCtrl.dispose();
    _trapLeavesCtrl.dispose();
    _strongWindowCtrl.dispose();
    _refutationCtrl.dispose();
    _verifyDepthCtrl.dispose();
    _trapPlyCtrl.dispose();
    _trapGapCtrl.dispose();
    super.dispose();
  }

  HoleHuntConfig _buildConfig() {
    final defaults = widget.initialConfig ?? const HoleHuntConfig();
    return defaults.copyWith(
      attackerIsUser: _attackMode,
      discoveryDepth:
          int.tryParse(_discoveryDepthCtrl.text) ?? defaults.discoveryDepth,
      maxPly: int.tryParse(_maxPlyCtrl.text) ?? defaults.maxPly,
      maiaElo: int.tryParse(_maiaEloCtrl.text) ?? defaults.maiaElo,
      trapLeafCount:
          int.tryParse(_trapLeavesCtrl.text) ?? defaults.trapLeafCount,
      strongMoveWindowCp:
          int.tryParse(_strongWindowCtrl.text) ?? defaults.strongMoveWindowCp,
      refutationThresholdCp:
          int.tryParse(_refutationCtrl.text) ?? defaults.refutationThresholdCp,
      verifyDepth: int.tryParse(_verifyDepthCtrl.text) ?? defaults.verifyDepth,
      trapSearchPly: int.tryParse(_trapPlyCtrl.text) ?? defaults.trapSearchPly,
      practicalGapThresholdCp:
          int.tryParse(_trapGapCtrl.text) ?? defaults.practicalGapThresholdCp,
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
                'tries with no reply in the file\n'
                '• Refutations — $treeColor moves that lose after a '
                'verified Stockfish reply\n'
                '• Practical traps — at frequently reached leaves, Maia '
                'expectimax finds lines that score far better for the '
                'attacker than the raw engine eval suggests',
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 6),
              const Text(
                'Results are ranked by reach probability × gain, so you '
                'get a short list of killer holes — not every bad eval.',
                style: AppTextStyles.caption,
              ),
              const SizedBox(height: 12),

              // Direction (framing only)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text(
                      'Attack this player',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(
                      'Stress-test my own play',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                selected: {_attackMode},
                onSelectionChanged: (s) =>
                    setState(() => _attackMode = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _attackMode
                    ? 'You play $attackerColor against these $treeColor lines.'
                    : 'Finds what a prepared $attackerColor opponent could '
                          'exploit in these games.',
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
                  _numField(
                    _maiaEloCtrl,
                    'Maia rating',
                    tooltip:
                        'Playing strength of the Maia human model used in '
                        'the trap search.',
                  ),
                  _numField(
                    _trapLeavesCtrl,
                    'Positions to trap-check',
                    tooltip:
                        'How many end-of-line positions (highest reach '
                        'probability first) get the Maia expectimax trap '
                        'search.',
                  ),
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
                    _numField(
                      _trapPlyCtrl,
                      'Trap search depth (half-moves)',
                      tooltip:
                          'How far past each end-of-line position the '
                          'expectimax trap search looks, in half-moves.',
                    ),
                    _numField(
                      _trapGapCtrl,
                      'Practical gap (centipawns)',
                      tooltip:
                          'Minimum gap between the practical (expectimax) '
                          'eval and the raw engine eval to flag a trap.',
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Pass 1 walks the tree with Stockfish; pass 2 runs Maia '
                'expectimax on the top leaves for practical traps. Can take '
                'a while — it keeps working while you browse.',
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
