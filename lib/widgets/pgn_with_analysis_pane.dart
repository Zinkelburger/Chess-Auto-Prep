/// PGN editor with a resizable analysis dock (Engine / Expectimax tabs).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/move_tree.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../theme/app_colors.dart';
import '../utils/lines_filter_helpers.dart' show isPlaceholderLineTitle;
import '../utils/pgn_utils.dart' as pgn_utils;
import 'analysis/analysis_panels_dialog.dart';
import 'layout/edit_main_zone.dart';
import 'repertoire_analysis_dock.dart';

/// Analysis dock on top, PGN editor below (resizable split).
class PgnWithAnalysisPane extends StatefulWidget {
  final RepertoireController controller;
  final MoveTree tree;
  final TreePath currentPath;
  final ValueChanged<TreePath>? onJump;
  final void Function(TreePath, String?)? onCommentChanged;
  final void Function(TreePath, int)? onToggleNag;
  final void Function(TreePath)? onDelete;
  final void Function(TreePath)? onPromote;
  final void Function(TreePath)? onMakeMainLine;
  final String repertoireColor;
  final bool isEditingExistingLine;
  final void Function(String updatedPgn)? onLineEdited;
  final VoidCallback onImportPgn;
  final VoidCallback? onViewInLines;
  final VoidCallback onReload;
  final BuildTree? generatedTree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isAnalysisActive;
  final bool embedAnalysisDock;

  /// Read-only header shown instead of the title field for ephemeral lines
  /// (e.g. "Trap #45 · Sicilian Defense").
  final String? ephemeralTitle;

  const PgnWithAnalysisPane({
    super.key,
    required this.controller,
    required this.tree,
    required this.currentPath,
    this.onJump,
    this.onCommentChanged,
    this.onToggleNag,
    this.onDelete,
    this.onPromote,
    this.onMakeMainLine,
    required this.repertoireColor,
    required this.isEditingExistingLine,
    this.onLineEdited,
    required this.onImportPgn,
    this.onViewInLines,
    required this.onReload,
    this.generatedTree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    required this.isAnalysisActive,
    this.embedAnalysisDock = true,
    this.ephemeralTitle,
  });

  @override
  State<PgnWithAnalysisPane> createState() => _PgnWithAnalysisPaneState();
}

class _PgnWithAnalysisPaneState extends State<PgnWithAnalysisPane> {
  static const _kAnalysisFraction = 'pgn_analysis.analysis_fraction';
  static const _kLegacyPgnFraction = 'pgn_analysis.pgn_fraction';
  static const _kShowDock = 'pgn_analysis.show_dock';

  double _analysisFraction = 0.42;
  bool _showDock = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        final analysis = prefs.getDouble(_kAnalysisFraction);
        if (analysis != null) {
          _analysisFraction = analysis;
        } else {
          final legacy = prefs.getDouble(_kLegacyPgnFraction);
          _analysisFraction = legacy != null
              ? (1.0 - legacy).clamp(0.22, 0.65)
              : 0.42;
        }
        _showDock = prefs.getBool(_kShowDock) ?? true;
      });
    } catch (e) {
      debugPrint('[PgnWithAnalysisPane] Failed to load prefs: $e');
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kAnalysisFraction, _analysisFraction);
      await prefs.setBool(_kShowDock, _showDock);
    } catch (e) {
      debugPrint('[PgnWithAnalysisPane] Failed to save prefs: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (!widget.embedAnalysisDock || !_showDock) {
                return _buildPgnEditor();
              }
              final total = constraints.maxHeight;
              final dockHeight = (total * _analysisFraction).clamp(
                120.0,
                total - 100,
              );
              final pgnHeight = total - dockHeight - 8;

              return Column(
                children: [
                  SizedBox(
                    height: dockHeight,
                    child: RepertoireAnalysisDock(
                      controller: widget.controller,
                      tree: widget.generatedTree,
                      treeConfig: widget.treeConfig,
                      fenMap: widget.fenMap,
                      boardPreview: widget.boardPreview,
                      coherenceResult: widget.coherenceResult,
                      isActive: widget.isAnalysisActive,
                    ),
                  ),
                  _SplitHandle(
                    onDrag: (dy) {
                      setState(() {
                        final next = dockHeight + dy;
                        _analysisFraction = (next / total).clamp(0.22, 0.65);
                      });
                      unawaited(_savePrefs());
                    },
                  ),
                  SizedBox(height: pgnHeight, child: _buildPgnEditor()),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          _ImportPgnPill(onPressed: widget.onImportPgn),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            // Says what it is for. "Reload repertoire" described the
            // mechanism and left the reason to guess at.
            tooltip: 'Check disk for changes',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: widget.onReload,
          ),
          IconButton(
            icon: const Icon(Icons.view_column, size: 20),
            tooltip: 'Analysis panels',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => showAnalysisPanelsDialog(context),
          ),
          if (widget.embedAnalysisDock)
            TextButton.icon(
              onPressed: () {
                setState(() => _showDock = !_showDock);
                unawaited(_savePrefs());
              },
              icon: Icon(
                _showDock ? Icons.expand_more : Icons.expand_less,
                size: 16,
              ),
              label: Text(
                _showDock ? 'Hide analysis' : 'Show analysis',
                style: const TextStyle(fontSize: 12),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  /// Title of the selected line (its PGN Event header, falling back to the
  /// display name), or null when composing a new line.
  String? _selectedLineTitle() {
    final line = widget.controller.selectedPgnLine;
    if (line == null) return null;
    final event = pgn_utils.extractEventTitle(line.fullPgn);
    return isPlaceholderLineTitle(event) ? line.name : event;
  }

  Widget _buildPgnEditor() {
    return EditMainZone(
      tree: widget.tree,
      currentPath: widget.currentPath,
      lineTitle: _selectedLineTitle(),
      onJump: widget.onJump,
      onCommentChanged: widget.onCommentChanged,
      onToggleNag: widget.onToggleNag,
      onDelete: widget.onDelete,
      onPromote: widget.onPromote,
      onMakeMainLine: widget.onMakeMainLine,
      repertoireColor: widget.repertoireColor,
      isEditingExistingLine: widget.isEditingExistingLine,
      onLineEdited: widget.onLineEdited,
      onViewInLines: widget.onViewInLines,
      ephemeralTitle: widget.ephemeralTitle,
    );
  }
}

class _SplitHandle extends StatefulWidget {
  final void Function(double dy) onDrag;
  const _SplitHandle({required this.onDrag});

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragStart: (_) => setState(() => _dragging = true),
      onVerticalDragUpdate: (d) => widget.onDrag(d.delta.dy),
      onVerticalDragEnd: (_) => setState(() => _dragging = false),
      onVerticalDragCancel: () => setState(() => _dragging = false),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: 8,
          color: Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _dragging ? 56 : 40,
              height: 3,
              decoration: BoxDecoration(
                color: _dragging
                    ? AppColors.expectimax
                    : AppColors.onSurfaceDim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the one import dialog. It used to be a popup menu asking "file or
/// paste?" — a question the dialog itself answers better, since it shows both
/// at once and lets a mis-picked file be replaced without reopening anything.
class _ImportPgnPill extends StatelessWidget {
  final VoidCallback onPressed;

  const _ImportPgnPill({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, size: 14, color: cs.onPrimaryContainer),
                const SizedBox(width: 5),
                Text(
                  'Import PGN',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
