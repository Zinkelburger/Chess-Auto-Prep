/// PGN editor with a resizable analysis dock (Engine / Expectimax tabs).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/move_tree.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../theme/app_colors.dart';
import 'analysis/analysis_settings_sheet.dart';
import 'layout/edit_main_zone.dart';
import 'repertoire_analysis_dock.dart';

/// Analysis dock on top, PGN editor below (resizable split).
class PgnWithAnalysisPane extends StatefulWidget {
  final RepertoireController controller;
  final MoveTree tree;
  final TreePath currentPath;
  final ValueChanged<TreePath>? onJump;
  final void Function(TreePath, String?)? onCommentChanged;
  final void Function(TreePath)? onDelete;
  final void Function(TreePath)? onPromote;
  final void Function(TreePath)? onMakeMainLine;
  final String? repertoireName;
  final String repertoireColor;
  final bool isEditingExistingLine;
  final void Function(String updatedPgn)? onLineEdited;
  final VoidCallback onImportPgnFile;
  final VoidCallback onImportPgnPaste;
  final VoidCallback? onViewInLines;
  final VoidCallback onReload;
  final BuildTree? generatedTree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool isAnalysisActive;
  final bool isGenerating;
  final bool isGenerationPaused;
  final bool embedAnalysisDock;
  final TrapIndexService? trapIndex;

  const PgnWithAnalysisPane({
    super.key,
    required this.controller,
    required this.tree,
    required this.currentPath,
    this.onJump,
    this.onCommentChanged,
    this.onDelete,
    this.onPromote,
    this.onMakeMainLine,
    this.repertoireName,
    required this.repertoireColor,
    required this.isEditingExistingLine,
    this.onLineEdited,
    required this.onImportPgnFile,
    required this.onImportPgnPaste,
    this.onViewInLines,
    required this.onReload,
    this.generatedTree,
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
              final dockHeight =
                  (total * _analysisFraction).clamp(120.0, total - 100);
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
                      isGenerating: widget.isGenerating,
                      isGenerationPaused: widget.isGenerationPaused,
                    ),
                  ),
                  _SplitHandle(
                    onDrag: (dy) {
                      setState(() {
                        final next = dockHeight + dy;
                        _analysisFraction = (next / total).clamp(0.22, 0.65);
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
          _AddPgnPill(
            onFile: widget.onImportPgnFile,
            onPaste: widget.onImportPgnPaste,
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
          if (widget.embedAnalysisDock)
            TextButton.icon(
              onPressed: () {
                setState(() => _showDock = !_showDock);
                _savePrefs();
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

  Widget _buildPgnEditor() {
    return EditMainZone(
      tree: widget.tree,
      currentPath: widget.currentPath,
      onJump: widget.onJump,
      onCommentChanged: widget.onCommentChanged,
      onDelete: widget.onDelete,
      onPromote: widget.onPromote,
      onMakeMainLine: widget.onMakeMainLine,
      repertoireName: widget.repertoireName,
      repertoireColor: widget.repertoireColor,
      isEditingExistingLine: widget.isEditingExistingLine,
      onLineEdited: widget.onLineEdited,
      onViewInLines: widget.onViewInLines,
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

class _AddPgnPill extends StatelessWidget {
  final VoidCallback onFile;
  final VoidCallback onPaste;

  const _AddPgnPill({required this.onFile, required this.onPaste});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      tooltip: 'Add PGN (I)',
      onSelected: (v) {
        if (v == 'file') onFile();
        if (v == 'paste') onPaste();
      },
      offset: const Offset(0, 30),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'file',
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.file_open, size: 16, color: cs.onSurface),
              const SizedBox(width: 8),
              const Text('Pick .pgn file', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.paste, size: 16, color: cs.onSurface),
              const SizedBox(width: 8),
              const Text('Paste PGN', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 14, color: cs.onPrimaryContainer),
            const SizedBox(width: 4),
            Text(
              'Add PGN',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
