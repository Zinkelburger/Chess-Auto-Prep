/// Compact inline expectimax bar — toggleable display of the built tree's
/// expectimax values at the current position.
///
/// Modeled on [InlineEngineBar]: a toggle switch over [ExpectimaxPanelHost].
/// Unlike the engine bar it never starts Stockfish — everything it shows was
/// stored at build time.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart';
import '../../services/coherence_service.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import 'expectimax_panel_host.dart';

class InlineExpectimaxBar extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;

  /// Show this FEN instead of the controller cursor (e.g. the
  /// build-by-playing scratchpad position).
  final String? fenOverride;

  const InlineExpectimaxBar({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    this.fenOverride,
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

  void _toggleEnabled(bool value) => setState(() => _enabled = value);

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
              compact: true,
              fenOverride: widget.fenOverride,
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
          const Expanded(
            child: Tooltip(
              message: 'Toggle expectimax (X)',
              child: Text(
                'Expectimax',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
