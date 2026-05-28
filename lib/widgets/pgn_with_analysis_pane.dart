/// PGN editor with a resizable analysis dock (Engine / Expectimax tabs).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../theme/app_colors.dart';
import 'analysis/analysis_settings_sheet.dart';
import 'interactive_pgn_editor.dart';
import 'layout/edit_main_zone.dart';
import 'repertoire_analysis_dock.dart';

/// Analysis dock on top, PGN editor below (resizable split).
class PgnWithAnalysisPane extends StatefulWidget {
  final RepertoireController controller;
  final PgnEditorController pgnEditorController;
  final String editorKeySuffix;
  final String initialPgn;
  final String? repertoireName;
  final String repertoireColor;
  final List<String> moveHistory;
  final int currentMoveIndex;
  final String? startingFen;
  final void Function(int moveIndex, List<String> moves) onMoveStateChanged;
  final void Function(dynamic position) onPositionChanged;
  final void Function(String pgn) onPgnChanged;
  final bool isEditingExistingLine;
  final void Function(String updatedPgn)? onLineEdited;
  final void Function(List<String> moves, String title, String pgn)? onLineSaved;
  final VoidCallback onImportPgn;
  final VoidCallback onReload;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isAnalysisActive;
  final bool isGenerating;
  final bool isGenerationPaused;

  /// When false, only the PGN editor + toolbar are shown (analysis lives in
  /// [EditContextZone] / wide layout context column).
  final bool embedAnalysisDock;

  final TrapIndexService? trapIndex;

  const PgnWithAnalysisPane({
    super.key,
    required this.controller,
    required this.pgnEditorController,
    required this.editorKeySuffix,
    required this.initialPgn,
    this.repertoireName,
    required this.repertoireColor,
    required this.moveHistory,
    required this.currentMoveIndex,
    this.startingFen,
    required this.onMoveStateChanged,
    required this.onPositionChanged,
    required this.onPgnChanged,
    required this.isEditingExistingLine,
    this.onLineEdited,
    this.onLineSaved,
    required this.onImportPgn,
    required this.onReload,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    required this.isAnalysisActive,
    this.isGenerating = false,
    this.isGenerationPaused = false,
    this.embedAnalysisDock = true,
    this.trapIndex,
  });

  @override
  State<PgnWithAnalysisPane> createState() => _PgnWithAnalysisPaneState();
}

class _PgnWithAnalysisPaneState extends State<PgnWithAnalysisPane> {
  static const _kAnalysisFraction = 'pgn_analysis.analysis_fraction';
  static const _kLegacyPgnFraction = 'pgn_analysis.pgn_fraction';
  static const _kShowDock = 'pgn_analysis.show_dock';

  /// Share of vertical space for Stockfish + expectimax (top of tab).
  double _analysisFraction = 0.42;
  bool _showDock = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
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
          _analysisFraction =
              legacy != null ? (1.0 - legacy).clamp(0.22, 0.65) : 0.42;
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
              final dockHeight = (total * _analysisFraction)
                  .clamp(120.0, total - 100);
              final pgnHeight = total - dockHeight - 8;

              return Column(
                children: [
                  SizedBox(
                    height: dockHeight,
                    child: RepertoireAnalysisDock(
                      controller: widget.controller,
                      tree: widget.tree,
                      treeConfig: widget.treeConfig,
                      fenMap: widget.fenMap,
                      boardPreview: widget.boardPreview,
                      coherenceResult: widget.coherenceResult,
                      isActive: widget.isAnalysisActive,
                      isGenerating: widget.isGenerating,
                      isGenerationPaused: widget.isGenerationPaused,
                    ),
                  ),
                  _SplitHandle(
                    onDrag: (dy) {
                      setState(() {
                        final next = dockHeight + dy;
                        _analysisFraction =
                            (next / total).clamp(0.22, 0.65);
                      });
                      _savePrefs();
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
          IconButton(
            icon: const Icon(Icons.upload_file, size: 20),
            tooltip: 'Import PGN',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: widget.onImportPgn,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Reload repertoire',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: widget.onReload,
          ),
          IconButton(
            icon: const Icon(Icons.tune, size: 20),
            tooltip: 'Analysis settings',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => showAnalysisSettingsSheet(context),
          ),
          TextButton.icon(
            onPressed: widget.embedAnalysisDock
                ? () {
                    setState(() => _showDock = !_showDock);
                    _savePrefs();
                  }
                : null,
            icon: Icon(
              _showDock ? Icons.expand_more : Icons.expand_less,
              size: 16,
            ),
            label: Text(
              widget.embedAnalysisDock
                  ? (_showDock ? 'Hide analysis' : 'Show analysis')
                  : 'Analysis in context panel',
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

  Widget _buildPgnEditor() {
    return EditMainZone(
      pgnEditorController: widget.pgnEditorController,
      editorKeySuffix: widget.editorKeySuffix,
      initialPgn: widget.initialPgn,
      repertoireName: widget.repertoireName,
      repertoireColor: widget.repertoireColor,
      moveHistory: widget.moveHistory,
      currentMoveIndex: widget.currentMoveIndex,
      startingFen: widget.startingFen,
      onMoveStateChanged: widget.onMoveStateChanged,
      onPositionChanged: widget.onPositionChanged,
      onPgnChanged: widget.onPgnChanged,
      isEditingExistingLine: widget.isEditingExistingLine,
      onLineEdited: widget.onLineEdited,
      onLineSaved: widget.onLineSaved,
      trapIndex: widget.trapIndex,
      boardPreview: widget.boardPreview,
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
                color: _dragging ? AppColors.expectimax : Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
