/// Config dialog for engine weakness analysis.
///
/// Returns an [EngineWeaknessConfig] when the user taps "Start", or null
/// if cancelled.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/engine_settings.dart';
import '../models/opening_tree.dart';
import '../utils/chess_utils.dart' show formatRam;

/// Settings returned by the config dialog.
class EngineWeaknessConfig {
  final int depth;
  final int minGames;
  final int whiteCp;
  final int blackCp;
  final int workers;
  final int maxLoadPercent;

  const EngineWeaknessConfig({
    required this.depth,
    required this.minGames,
    required this.whiteCp,
    required this.blackCp,
    required this.workers,
    required this.maxLoadPercent,
  });
}

class EngineWeaknessConfigDialog extends StatefulWidget {
  final OpeningTree? whiteTree;
  final OpeningTree? blackTree;

  const EngineWeaknessConfigDialog({
    super.key,
    this.whiteTree,
    this.blackTree,
  });

  @override
  State<EngineWeaknessConfigDialog> createState() =>
      _EngineWeaknessConfigDialogState();
}

class _EngineWeaknessConfigDialogState
    extends State<EngineWeaknessConfigDialog> {
  late final TextEditingController _depthCtrl;
  late final TextEditingController _minGamesCtrl;
  late final TextEditingController _whiteCpCtrl;
  late final TextEditingController _blackCpCtrl;
  late final TextEditingController _workersCtrl;
  late final TextEditingController _maxLoadCtrl;

  @override
  void initState() {
    super.initState();
    final settings = EngineSettings();
    _depthCtrl = TextEditingController(text: '20');
    _minGamesCtrl = TextEditingController(text: '3');
    _whiteCpCtrl = TextEditingController(text: '-50');
    _blackCpCtrl = TextEditingController(text: '100');
    _workersCtrl = TextEditingController(text: '${settings.cores}');
    _maxLoadCtrl = TextEditingController(text: '${settings.maxSystemLoad}');
  }

  @override
  void dispose() {
    _depthCtrl.dispose();
    _minGamesCtrl.dispose();
    _whiteCpCtrl.dispose();
    _blackCpCtrl.dispose();
    _workersCtrl.dispose();
    _maxLoadCtrl.dispose();
    super.dispose();
  }

  int get _positionCount {
    final minGames = int.tryParse(_minGamesCtrl.text) ?? 3;
    int count = 0;
    for (final tree in [widget.whiteTree, widget.blackTree]) {
      if (tree == null) continue;
      for (final nodes in tree.fenToNodes.values) {
        if (nodes.isEmpty) continue;
        final best =
            nodes.reduce((a, b) => a.gamesPlayed >= b.gamesPlayed ? a : b);
        if (best.gamesPlayed >= minGames) count++;
      }
    }
    return count;
  }

  String get _resourceSummary {
    final workers = int.tryParse(_workersCtrl.text) ?? EngineSettings().cores;
    final load =
        int.tryParse(_maxLoadCtrl.text) ?? EngineSettings().maxSystemLoad;
    final ramMb = EngineSettings.systemRamMb;
    final hashBudget = (ramMb * load ~/ 100).clamp(64, ramMb);
    final hashPer = workers > 0
        ? (hashBudget / (workers + 1)).floor().clamp(16, hashBudget)
        : hashBudget;
    return 'Up to $workers workers, $hashPer MB hash/worker '
        '(${formatRam(ramMb)} system RAM)';
  }

  void _submit() {
    Navigator.of(context).pop(EngineWeaknessConfig(
      depth: int.tryParse(_depthCtrl.text) ?? 20,
      minGames: int.tryParse(_minGamesCtrl.text) ?? 3,
      whiteCp: int.tryParse(_whiteCpCtrl.text) ?? -50,
      blackCp: int.tryParse(_blackCpCtrl.text) ?? 100,
      workers: int.tryParse(_workersCtrl.text) ?? EngineSettings().cores,
      maxLoadPercent:
          int.tryParse(_maxLoadCtrl.text) ?? EngineSettings().maxSystemLoad,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              const Divider(height: 24),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _field('Depth', _depthCtrl, 80),
                  _field('Min games', _minGamesCtrl, 80),
                  _field('CP score (white)', _whiteCpCtrl, 120),
                  _field('CP score (black)', _blackCpCtrl, 120),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _field('Workers', _workersCtrl, 80),
                  _field('Max load %', _maxLoadCtrl, 80),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _resourceSummary,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[500],
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '$_positionCount positions will be evaluated'
                '${widget.whiteTree != null && widget.blackTree != null ? ' (both colors)' : ''}',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.psychology, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Engine Weakness Analysis',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              Text(
                'Find weak positions according to the engine',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController ctrl, double width) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        SizedBox(
          width: width,
          child: TextField(
            controller: ctrl,
            style: const TextStyle(fontSize: 13),
            keyboardType:
                const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );
  }
}
