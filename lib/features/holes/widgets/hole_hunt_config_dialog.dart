/// Hole-hunt configuration dialog for Player Analysis.
///
/// Collects a [HoleHuntConfig] and pops with it; the host screen owns the
/// hunt lifecycle. The hunt attacks the displayed colour's game tree from
/// the opposite side: uncovered strong moves, refutations, and (via the
/// end-of-line expectimax pass) practical traps.
library;

import 'package:flutter/material.dart';

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
    _strongWindowCtrl =
        TextEditingController(text: '${c.strongMoveWindowCp}');
    _refutationCtrl =
        TextEditingController(text: '${c.refutationThresholdCp}');
    _verifyDepthCtrl = TextEditingController(text: '${c.verifyDepth}');
    _trapPlyCtrl = TextEditingController(text: '${c.trapSearchPly}');
    _trapGapCtrl =
        TextEditingController(text: '${c.practicalGapThresholdCp}');
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
      strongMoveWindowCp: int.tryParse(_strongWindowCtrl.text) ??
          defaults.strongMoveWindowCp,
      refutationThresholdCp: int.tryParse(_refutationCtrl.text) ??
          defaults.refutationThresholdCp,
      verifyDepth: int.tryParse(_verifyDepthCtrl.text) ?? defaults.verifyDepth,
      trapSearchPly:
          int.tryParse(_trapPlyCtrl.text) ?? defaults.trapSearchPly,
      practicalGapThresholdCp: int.tryParse(_trapGapCtrl.text) ??
          defaults.practicalGapThresholdCp,
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
                'Attacks ${widget.playerName}\'s games as $treeColor from '
                'the $attackerColor side: uncovered strong moves, concrete '
                'refutations, and end-of-line practical traps found with '
                'Stockfish + Maia expectimax.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),

              // Direction (framing only)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('Attack this player',
                        style: TextStyle(fontSize: 12)),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('Stress-test my own play',
                        style: TextStyle(fontSize: 12)),
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
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
              const SizedBox(height: 16),

              // Key knobs
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField(_discoveryDepthCtrl, 'Search Depth'),
                  _numField(_maxPlyCtrl, 'Max Ply'),
                  _numField(_maiaEloCtrl, 'Maia Elo'),
                  _numField(_trapLeavesCtrl, 'Trap Leaves'),
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
                      color: Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Text('More thresholds',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[500])),
                  ],
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _numField(_strongWindowCtrl, 'Strong Move Window (cp)'),
                    _numField(_refutationCtrl, 'Refutation Threshold (cp)'),
                    _numField(_verifyDepthCtrl, 'Verification Depth'),
                    _numField(_trapPlyCtrl, 'Trap Search Ply'),
                    _numField(_trapGapCtrl, 'Practical Gap (cp)'),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'The hunt runs the engine over the whole tree and can take '
                'a while; it keeps working while you browse.',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
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

  Widget _numField(TextEditingController ctrl, String label) {
    return SizedBox(
      width: 200,
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
  }
}
