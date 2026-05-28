/// Centralized settings screen accessible from the app bar.
///
/// Groups all persistent configuration: Engine, Database, Generation,
/// Training, and Display settings in a single scrollable view.
library;

import 'package:flutter/material.dart';

import '../models/engine_settings.dart';
import '../theme/app_colors.dart';
import '../utils/system_info.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _engine = EngineSettings();

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    _engine.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cores = getLogicalCores();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsGroup(
            title: 'Engine',
            icon: Icons.bolt,
            children: [
              _SliderTile(
                label: 'Workers (interactive)',
                value: _engine.workers,
                min: 1,
                max: cores,
                suffix: '/ $cores cores',
                onChanged: (v) => _engine.workers = v,
              ),
              _SliderTile(
                label: 'Search depth',
                value: _engine.depth,
                min: 1,
                max: 40,
                onChanged: (v) => _engine.depth = v,
              ),
              _SliderTile(
                label: 'MultiPV',
                value: _engine.multiPv,
                min: 1,
                max: 10,
                onChanged: (v) => _engine.multiPv = v,
              ),
              _SliderTile(
                label: 'Max analysis moves',
                value: _engine.maxAnalysisMoves,
                min: 3,
                max: 20,
                onChanged: (v) => _engine.maxAnalysisMoves = v,
              ),
              _SliderTile(
                label: 'Inline threads (PGN viewer)',
                value: _engine.inlineThreads,
                min: 1,
                max: cores,
                onChanged: (v) => _engine.inlineThreads = v,
              ),
              _SliderTile(
                label: 'Maia ELO',
                value: _engine.maiaElo,
                min: 600,
                max: 2400,
                divisions: 18,
                onChanged: (v) => _engine.maiaElo = v,
              ),
              _SliderTile(
                label: 'On-the-fly expectimax depth',
                value: _engine.onTheFlyMaxDepth,
                min: 1,
                max: 12,
                onChanged: (v) => _engine.onTheFlyMaxDepth = v,
              ),
              _SwitchTile(
                label: 'Show Stockfish analysis',
                value: _engine.showStockfish,
                onChanged: (v) => _engine.showStockfish = v,
              ),
              _SwitchTile(
                label: 'Show Maia probabilities',
                value: _engine.showMaia,
                onChanged: (v) => _engine.showMaia = v,
              ),
              _SwitchTile(
                label: 'Show probability',
                value: _engine.showProbability,
                onChanged: (v) => _engine.showProbability = v,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Reset All to Defaults'),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Reset Settings'),
                    content: const Text(
                        'Reset all settings to factory defaults?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          _engine.resetToDefaults();
                          Navigator.pop(ctx);
                        },
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Chess Auto Prep',
              style: TextStyle(
                  color: Colors.grey[600], fontSize: 11),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SettingsGroup({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 16),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.pgnMainLine),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey[800]!, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final int? divisions;
  final String? suffix;
  final ValueChanged<int> onChanged;

  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(label,
                style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions ?? (max - min),
              label: '$value',
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              suffix != null ? '$value $suffix' : '$value',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(fontSize: 13)),
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      dense: true,
    );
  }
}
