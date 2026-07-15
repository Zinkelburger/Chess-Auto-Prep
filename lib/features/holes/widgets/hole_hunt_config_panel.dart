/// Hole-hunt configuration panel — direction, depths, Start/Cancel,
/// progress. Rendered inline in the Jobs tab (mirrors [AuditConfigPanel]).
///
/// Triggers hunts and reports results back to the screen via callbacks.
library;

import 'package:flutter/material.dart';

import '../../../models/opening_tree.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/engine/engine_gate.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../services/hole_hunt_config.dart';
import '../services/hole_hunt_service.dart';

class HoleHuntConfigPanel extends StatefulWidget {
  final OpeningTree? openingTree;
  final bool isWhiteRepertoire;
  final String? repertoireFilePath;

  /// External service reference so pause/resume/cancel are accessible.
  final HoleHuntService? huntService;

  final void Function(bool hunting) onHuntingChanged;
  final void Function(AuditResult result) onResultReady;
  final void Function(AuditFinding finding)? onLiveFinding;
  final void Function(HoleHuntProgress progress)? onProgress;
  final void Function(HoleHuntConfig config)? onConfigChanged;

  const HoleHuntConfigPanel({
    super.key,
    required this.openingTree,
    required this.isWhiteRepertoire,
    this.repertoireFilePath,
    this.huntService,
    required this.onHuntingChanged,
    required this.onResultReady,
    this.onLiveFinding,
    this.onProgress,
    this.onConfigChanged,
  });

  @override
  State<HoleHuntConfigPanel> createState() => HoleHuntConfigPanelState();
}

class HoleHuntConfigPanelState extends State<HoleHuntConfigPanel> {
  HoleHuntService? _ownedService;
  HoleHuntService get _service =>
      widget.huntService ?? (_ownedService ??= HoleHuntService());

  final TextEditingController _discoveryDepthCtrl =
      TextEditingController(text: '14');
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '30');
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2000');
  final TextEditingController _trapLeavesCtrl =
      TextEditingController(text: '12');
  final TextEditingController _strongWindowCtrl =
      TextEditingController(text: '30');
  final TextEditingController _refutationCtrl =
      TextEditingController(text: '80');
  final TextEditingController _verifyDepthCtrl =
      TextEditingController(text: '20');
  final TextEditingController _trapPlyCtrl = TextEditingController(text: '6');
  final TextEditingController _trapGapCtrl = TextEditingController(text: '60');

  /// True = "Attack this repertoire", false = "Stress-test my own".
  /// Framing only — the attacker is always the side opposite the file.
  bool _attackMode = true;

  bool _isHunting = false;
  HoleHuntProgress? _progress;
  int _liveFindingCount = 0;
  bool _showAdvanced = false;

  bool get isHunting => _isHunting;

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

  // ── Hunt lifecycle ─────────────────────────────────────────────────────

  void cancelHunt() {
    _service.cancel();
    if (mounted) setState(() => _isHunting = false);
    widget.onHuntingChanged(false);
    EngineLifecycle.instance.exitGeneration();
  }

  HoleHuntConfig _buildConfig() {
    return HoleHuntConfig(
      attackerIsUser: _attackMode,
      discoveryDepth: int.tryParse(_discoveryDepthCtrl.text) ?? 14,
      maxPly: int.tryParse(_maxPlyCtrl.text) ?? 30,
      maiaElo: int.tryParse(_maiaEloCtrl.text) ?? 2000,
      trapLeafCount: int.tryParse(_trapLeavesCtrl.text) ?? 12,
      strongMoveWindowCp: int.tryParse(_strongWindowCtrl.text) ?? 30,
      refutationThresholdCp: int.tryParse(_refutationCtrl.text) ?? 80,
      verifyDepth: int.tryParse(_verifyDepthCtrl.text) ?? 20,
      trapSearchPly: int.tryParse(_trapPlyCtrl.text) ?? 6,
      practicalGapThresholdCp: int.tryParse(_trapGapCtrl.text) ?? 60,
    );
  }

  Future<void> _startHunt() async {
    if (widget.openingTree == null) return;
    if (!EngineGate.ensureAvailable(context)) return;
    // The hunt shares the generation engine state; refuse to overlap with a
    // running generation or audit rather than contend for the same workers.
    if (EngineLifecycle.instance.state == EngineState.generating) {
      showAppSnackBar(
        context,
        'Another engine job is running — wait for it to finish first',
        isError: true,
      );
      return;
    }

    final config = _buildConfig();
    widget.onConfigChanged?.call(config);

    // Capture callbacks before the pane potentially closes and unmounts us.
    final onProgressCb = widget.onProgress;
    final onLiveFindingCb = widget.onLiveFinding;
    final onResultReadyCb = widget.onResultReady;
    final onHuntingChangedCb = widget.onHuntingChanged;
    final tree = widget.openingTree!;
    final isWhite = widget.isWhiteRepertoire;

    setState(() {
      _isHunting = true;
      _progress = null;
      _liveFindingCount = 0;
    });
    onHuntingChangedCb(true);

    await EngineLifecycle.instance.enterGeneration(1);
    await StockfishPool.instance.ensureWorkers(1);

    try {
      final result = await _service.hunt(
        tree: tree,
        isWhiteRepertoire: isWhite,
        config: config,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
          onProgressCb?.call(p);
        },
        onFinding: (f) {
          if (mounted) setState(() => _liveFindingCount++);
          onLiveFindingCb?.call(f);
        },
      );

      if (mounted) setState(() => _isHunting = false);
      onResultReadyCb(result);
    } catch (e) {
      if (mounted) setState(() => _isHunting = false);
    } finally {
      onHuntingChangedCb(false);
      EngineLifecycle.instance.exitGeneration();
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final attackerColor = widget.isWhiteRepertoire ? 'Black' : 'White';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Direction (framing only)
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('Attack this repertoire',
                    style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: false,
                label: Text('Stress-test my own repertoire',
                    style: TextStyle(fontSize: 11)),
              ),
            ],
            selected: {_attackMode},
            onSelectionChanged: _isHunting
                ? null
                : (s) => setState(() => _attackMode = s.first),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _attackMode
                ? 'You play $attackerColor against this file\'s lines.'
                : 'Finds what a prepared $attackerColor opponent could '
                    'exploit in this file.',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Icon(Icons.memory, size: 13, color: Colors.grey[500]),
              const SizedBox(width: 4),
              Text('Stockfish + Maia expectimax',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ],
          ),
          const SizedBox(height: 8),

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
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ),
          if (_showAdvanced) ...[
            const SizedBox(height: 6),
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
          const SizedBox(height: 10),

          // Start / Cancel + progress
          Row(
            children: [
              if (!_isHunting)
                FilledButton.icon(
                  onPressed: widget.openingTree == null ? null : _startHunt,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start', style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: cancelHunt,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Cancel', style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                ),
              if (_isHunting && _progress != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(value: _progress!.fraction),
                      const SizedBox(height: 2),
                      Text(
                        '${_progress!.message} · '
                        '$_liveFindingCount holes',
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _numField(TextEditingController ctrl, String label) {
    return SizedBox(
      width: 170,
      child: TextField(
        controller: ctrl,
        enabled: !_isHunting,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
    );
  }
}
