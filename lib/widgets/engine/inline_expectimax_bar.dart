/// Compact inline expectimax bar — toggleable display of expectimax PV lines.
///
/// Modeled on [InlineEngineBar]. Shows a toggle switch, live expectimax
/// lines from the precomputed tree or on-the-fly computation, and a
/// settings gear. Delegates all computation to [ExpectimaxPanelHost].
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart';
import '../../services/coherence_service.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import '../analysis/analysis_settings_sheet.dart';
import 'expectimax_panel_host.dart';

class InlineExpectimaxBar extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isGenerating;
  final bool isGenerationPaused;

  const InlineExpectimaxBar({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    this.isGenerating = false,
    this.isGenerationPaused = false,
  });

  static bool get isEnabled => _InlineExpectimaxBarState._enabled;

  static void toggle() => _InlineExpectimaxBarState.toggleExternal();

  @override
  State<InlineExpectimaxBar> createState() => _InlineExpectimaxBarState();
}

class _InlineExpectimaxBarState extends State<InlineExpectimaxBar> {
  static bool _enabled = false;
  static final _externalToggleNotifier = <VoidCallback>[];

  static void toggleExternal() {
    _enabled = !_enabled;
    for (final cb in _externalToggleNotifier) {
      cb();
    }
  }

  @override
  void initState() {
    super.initState();
    _externalToggleNotifier.add(_onExternalToggle);
  }

  @override
  void dispose() {
    _externalToggleNotifier.remove(_onExternalToggle);
    super.dispose();
  }

  void _onExternalToggle() {
    if (mounted) setState(() {});
  }

  void _toggleEnabled(bool value) {
    setState(() => _enabled = value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToggleBar(context),
        if (_enabled) ...[
          const Divider(height: 1),
          SizedBox(
            height: 120,
            child: ExpectimaxPanelHost(
              controller: widget.controller,
              tree: widget.tree,
              treeConfig: widget.treeConfig,
              fenMap: widget.fenMap,
              boardPreview: widget.boardPreview,
              coherenceResult: widget.coherenceResult,
              isGenerating: widget.isGenerating,
              isGenerationPaused: widget.isGenerationPaused,
              compact: true,
              autoComputeEnabled: _enabled,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildToggleBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          SizedBox(
            height: 24,
            child: FittedBox(
              child: Switch(
                value: _enabled,
                onChanged: _toggleEnabled,
                activeTrackColor: AppColors.expectimax,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: 'Toggle expectimax (X)',
              child: Text(
                'Expectimax',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ),
          ),
          if (_enabled)
            IconButton(
              icon: const Icon(Icons.settings, size: 18),
              tooltip: 'Expectimax Settings',
              onPressed: () => showAnalysisSettingsSheet(
                context,
                mode: AnalysisSettingsContext.full,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
        ],
      ),
    );
  }
}
