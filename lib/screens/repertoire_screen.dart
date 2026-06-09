/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/engine_settings.dart';
import '../models/repertoire_line.dart';
import '../services/repertoire_service.dart';
import '../utils/app_messages.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../widgets/coverage_calculator_widget.dart';
import '../widgets/pgn_with_analysis_pane.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/generation_config_dialog.dart';
import '../widgets/explorer_section.dart';
import '../widgets/layout/board_zone.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/layout/empty_state_placeholder.dart';
import '../widgets/layout/jobs_panel.dart';
import '../constants/ui_breakpoints.dart';
import '../widgets/repertoire/repertoire_toolbar.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/engine/inline_expectimax_bar.dart';
import '../services/jobs/repertoire_job.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/audit/widgets/audit_config_panel.dart';
import '../features/audit/widgets/audit_config_dialog.dart';
import '../features/audit/widgets/audit_findings_panel.dart';
import '../features/traps/widgets/trap_navigation_buttons.dart';
import '../features/traps/widgets/trap_walkthrough.dart';
import '../features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import '../services/generation/trap_extractor.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import 'repertoire_selection_screen.dart';

// -------------------------------------------------------------------
// REPERTOIRE SCREEN WIDGET
// -------------------------------------------------------------------

class RepertoireScreen extends StatefulWidget {
  const RepertoireScreen({super.key});

  @override
  State<RepertoireScreen> createState() => _RepertoireScreenState();
}

class _RepertoireScreenState extends State<RepertoireScreen>
    with TickerProviderStateMixin {
  late final RepertoireController _controller;
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  final GlobalKey<AuditConfigPanelState> _auditConfigKey =
      GlobalKey<AuditConfigPanelState>();
  bool _isGenerating = false;
  bool _isGenerationPaused = false;
  bool _isAuditing = false;
  bool _isCompactLayout = false;

  /// Audit results held at screen level so both config and findings panels
  /// can access them, and board annotations can read them directly.
  AuditResult? _auditResult;
  final List<AuditFinding> _liveFindings = [];

  final JobManager _jobManager = JobManager.instance;
  RepertoireJob? _currentGenJob;
  RepertoireJob? _currentAuditJob;

  BuildTree? _generatedTree;
  TreeBuildConfig? _generatedTreeConfig;
  FenMap? _generatedTreeFenMap;
  final BoardPreviewController _boardPreview = BoardPreviewController();
  final NavigationStack _navigationStack = NavigationStack();

  bool _boardFlipped = false;

  final CoherenceService _coherenceService = CoherenceService();

  List<TrapLineInfo> _traps = [];
  TrapIndexService? _trapIndex;
  bool _trapWalkthroughVisible = false;
  TrapLineInfo? _trapWalkthroughInitialTrap;
  int _trapWalkthroughSession = 0;

  CoverageResult? _coverageResult;
  bool _isCoverageRunning = false;
  double? _coverageProgress;
  String? _coverageProgressMessage;

  String? _lastRepertoireId;

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    _controller = RepertoireController();
    _controller.addListener(_onRepertoireChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.addListener(_onAppStateChanged);

      if (appState.pendingRepertoirePath != null) {
        _onAppStateChanged();
      } else if (_controller.currentRepertoire == null) {
        _showRepertoireSelection();
      }
    });
  }

  void _updateCompactLayout(bool isCompact) {
    if (_isCompactLayout == isCompact) return;
    _isCompactLayout = isCompact;
    setState(() {});
  }

  /// PGN is always active in the unified right pane (no tabs hiding it).
  bool get _isPgnTabActive => true;

  void _openJobsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 550, maxHeight: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    const Icon(Icons.work_outline, size: 20),
                    const SizedBox(width: 8),
                    Text('Jobs', style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Flexible(child: _buildJobsContent()),
            ],
          ),
        ),
      ),
    );
  }

  void _openFindingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    const Icon(Icons.assignment_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text('Audit Findings',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    if (_auditResult != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.error,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_auditResult!.activeFindingCount}',
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Flexible(child: _buildFindingsContent()),
            ],
          ),
        ),
      ),
    );
  }

  void _openGenerationDialog() {
    showGenerationConfigDialog(
      context,
      fen: _controller.fen,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      currentRepertoire: _controller.currentRepertoire,
      currentMoveSequence: _controller.currentMoveSequence,
      generationTabKey: _generationTabKey,
      onGeneratingChanged: _onGeneratingChanged,
      onPauseChanged: _onPauseChanged,
      onLineSaved: (moves, title, pgn) {
        _controller.appendNewLine(moves, title, pgn);
      },
      onTreeReset: _onTreeReset,
      onTreeBuilt: _onTreeBuilt,
    );
  }

  void _openAuditDialog() {
    showAuditConfigDialog(
      context,
      openingTree: _controller.openingTree,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      currentFen: _controller.fen,
      currentMoveSequence: _controller.currentMoveSequence,
      repertoireFilePath:
          _controller.currentRepertoire?['filePath'] as String?,
      auditConfigKey: _auditConfigKey,
      onAuditingChanged: (auditing) {
        if (!mounted) return;
        if (auditing && _currentAuditJob == null) {
          _currentAuditJob = _jobManager.createJob(
            type: JobType.audit,
            label:
                _controller.currentRepertoire?['name'] as String? ?? 'Audit',
          );
          _currentAuditJob!.updateStatus(JobStatus.running);
          _liveFindings.clear();
          _auditResult = null;
        } else if (!auditing && _currentAuditJob != null) {
          _currentAuditJob!.updateStatus(JobStatus.completed);
          _currentAuditJob = null;
        }
        setState(() => _isAuditing = auditing);
      },
      onResultReady: (result) {
        if (!mounted) return;
        setState(() {
          _auditResult = result;
          _liveFindings.clear();
        });
      },
      onLiveFinding: (finding) {
        if (!mounted) return;
        setState(() => _liveFindings.add(finding));
      },
    );
  }

  void _onAppStateChanged() {
    final appState = context.read<AppState>();
    if (appState.currentMode == AppMode.repertoire) {
      _reclaimFocus();
    }
    if (appState.currentMode == AppMode.repertoire &&
        appState.pendingRepertoirePath != null) {
      final path = appState.pendingRepertoirePath!;
      final lineId = appState.pendingLineId;
      appState.pendingRepertoirePath = null;
      appState.pendingLineId = null;

      // Load the requested repertoire if different from current
      final currentPath = _controller.currentRepertoire?['filePath'] as String?;
      if (currentPath != path) {
        _controller.setRepertoire({
          'filePath': path,
          'name': path.split('/').last.replaceAll('.pgn', '')
        });
      }
      // If a specific line was requested, navigate to it once loaded.
      // Use a listener instead of a single post-frame callback so we
      // don't miss the load if parsing takes more than one frame.
      if (lineId != null) {
        void waitForLine() {
          if (!mounted) {
            _controller.removeListener(waitForLine);
            return;
          }
          final line = _controller.repertoireLines
              .where((l) => l.id == lineId)
              .firstOrNull;
          if (line != null) {
            _controller.removeListener(waitForLine);
            _controller.loadPgnLine(line);
          }
        }

        _controller.addListener(waitForLine);
        // Also check immediately in case data is already loaded.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) waitForLine();
        });
      }

      final pendingPgnPaths = appState.pendingGenerationPgnPaths;
      if (pendingPgnPaths != null) {
        appState.pendingGenerationPgnPaths = null;
        _openGenerationDialog();
        void waitForGenerationTab() {
          if (!mounted) {
            _controller.removeListener(waitForGenerationTab);
            return;
          }
          if (_controller.isLoading) return;
          _controller.removeListener(waitForGenerationTab);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _generationTabKey.currentState?.seedDbExplorer(
              pgnPaths: pendingPgnPaths,
              autoStart: true,
            );
          });
        }

        _controller.addListener(waitForGenerationTab);
        // Also try immediately in case loading already finished.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) waitForGenerationTab();
        });
      }
    }
  }

  void _onRepertoireChanged() {
    if (!mounted) return;
    setState(() {
      if (_controller.currentRepertoire != null && !_controller.isLoading) {
        final currentId =
            _controller.currentRepertoire!['filePath'] as String?;
        if (currentId != null && currentId != _lastRepertoireId) {
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite;
          _generatedTree = null;
          _coverageResult = null;
          EngineSettings().probabilityStartMoves = _controller.rootMoves;
          _loadTraps(currentId);
        }

        if (_controller.needsColorSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showColorSelectionDialog();
          });
        }
      }
    });
  }

  Future<void> _showColorSelectionDialog() async {
    final name = _controller.currentRepertoire?['name'] ?? 'this repertoire';
    final isWhite = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Which color is this repertoire for?'),
        content: Text(
          '"$name" doesn\'t have a color set yet. '
          'This will be saved so you won\'t be asked again.',
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context, false),
            icon: const Icon(Icons.circle, color: Colors.black),
            label: const Text('Black'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.circle_outlined),
            label: const Text('White'),
          ),
        ],
      ),
    );
    if (isWhite != null) {
      await _controller.setRepertoireColor(isWhite);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _boardPreview.dispose();
    _controller.removeListener(_onRepertoireChanged);
    _controller.dispose();

    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (_) { /* provider may already be disposed */ }

    super.dispose();
  }

  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  Future<void> _performUndo() async {
    if (!_controller.writer.canUndo) return;
    try {
      final undone = await _controller.writer.undo();
      if (!mounted || !undone) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Undid last repertoire add'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('[RepertoireScreen] Undo failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Undo failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Skip keyboard shortcuts when a text field has focus.
    final primaryFocus = FocusManager.instance.primaryFocus;
    final isTextInput = primaryFocus?.context?.widget is EditableText;

    // Ctrl+Shift+V - Paste FEN from clipboard (even in text fields)
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isShiftPressed) {
      _pastePositionFromClipboard();
      return KeyEventResult.handled;
    }

    // All remaining shortcuts are suppressed when typing.
    if (isTextInput) return KeyEventResult.ignored;

    // Ctrl+Z — undo last repertoire add (browse / suggestion accept)
    if (event.logicalKey == LogicalKeyboardKey.keyZ &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _performUndo();
      return KeyEventResult.handled;
    }

    // 'G' key — open generation config dialog
    if (event.logicalKey == LogicalKeyboardKey.keyG &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      _openGenerationDialog();
      return KeyEventResult.handled;
    }

    // 'A' key — open audit config dialog
    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      _openAuditDialog();
      return KeyEventResult.handled;
    }

    // 'X' key — toggle expectimax bar
    if (event.logicalKey == LogicalKeyboardKey.keyX &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      InlineExpectimaxBar.toggle();
      return KeyEventResult.handled;
    }

    // '1' key — open Jobs dialog
    if (event.logicalKey == LogicalKeyboardKey.digit1 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _openJobsDialog();
      return KeyEventResult.handled;
    }

    // '2' key — open Findings dialog
    if (event.logicalKey == LogicalKeyboardKey.digit2 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _openFindingsDialog();
      return KeyEventResult.handled;
    }

    // 'F' key - Flip the board
    if (event.logicalKey == LogicalKeyboardKey.keyF &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      setState(() {
        _boardFlipped = !_boardFlipped;
      });
      return KeyEventResult.handled;
    }

    // 'T' key — toggle trap walkthrough at a trap position
    if (event.logicalKey == LogicalKeyboardKey.keyT &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      final trapIndex = _trapIndex;
      if (trapIndex != null && trapIndex.trapAtFen(_controller.fen) != null) {
        if (_trapWalkthroughVisible) {
          _closeTrapWalkthrough();
        } else {
          _openTrapWalkthrough(
            startTrap: trapIndex.trapAtFen(_controller.fen),
          );
        }
        return KeyEventResult.handled;
      }
    }

    // 'E' key — toggle engine
    if (event.logicalKey == LogicalKeyboardKey.keyE &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      InlineEngineBar.toggleEngine();
      return KeyEventResult.handled;
    }

    // Arrow keys — always through controller (single source of truth).
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (TrapNavigationButtons.goToPreviousTrap(
          trapIndex: _trapIndex,
          controller: _controller,
        )) {
          return KeyEventResult.handled;
        }
      }
      _controller.goBack();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (TrapNavigationButtons.goToNextTrap(
          trapIndex: _trapIndex,
          controller: _controller,
        )) {
          return KeyEventResult.handled;
        }
      }
      _controller.goForward();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (_controller.isLoading) {
      return Scaffold(
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          onOpenSettings: () async {
            await openRepertoireSettings(context);
            _reclaimFocus();
          },
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading repertoire...'),
            ],
          ),
        ),
      );
    }

    // No repertoire selected
    if (_controller.currentRepertoire == null) {
      return Scaffold(
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          showSelectRepertoireAction: true,
          onOpenSettings: () async {
            await openRepertoireSettings(context);
            _reclaimFocus();
          },
          onSelectRepertoire: _showRepertoireSelection,
        ),
        body: EmptyStatePlaceholder(
          icon: Icons.library_books,
          title: 'No Repertoire Selected',
          actionLabel: 'Select Repertoire',
          actionIcon: Icons.library_books,
          onAction: _showRepertoireSelection,
        ),
      );
    }

    // Has repertoire selected - show repertoire UI
    final repertoire = _controller.currentRepertoire!;
    return Scaffold(
      appBar: RepertoireToolbar(
        title: RepertoireToolbarTitle(
          repertoireName: repertoire['name'] as String?,
          gameCount: repertoire['gameCount'] as int?,
        ),
        isGenerating: _isGenerating,
        isGenerationPaused: _isGenerationPaused,
        showTrainButton: true,
        showSelectRepertoireAction: true,
        generationLocked: _isGenerating,
        onOpenSettings: () async {
          await openRepertoireSettings(context);
          _reclaimFocus();
        },
        onSelectRepertoire: _showRepertoireSelection,
        onTrainRepertoire: _trainRepertoire,
        onOpenGeneration: _openGenerationDialog,
        onOpenAudit: _openAuditDialog,
        trapNavigation: _buildTrapNavigation(),
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onSwitchColor: () async {
          await _controller
              .setRepertoireColor(!_controller.isRepertoireWhite);
        },
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reclaimFocus,
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < kCompactBreakpoint;
                    if (isCompact != _isCompactLayout) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _updateCompactLayout(isCompact);
                      });
                    }
                    if (isCompact) {
                      return _buildCompactLayout();
                    }
                    return _buildWideLayout();
                  },
                ),
              ),
              if (_trapWalkthroughVisible && _trapIndex != null)
                TrapWalkthrough(
                  key: ValueKey(_trapWalkthroughSession),
                  trapIndex: _trapIndex!,
                  controller: _controller,
                  boardPreview: _boardPreview,
                  initialTrap: _trapWalkthroughInitialTrap,
                  onClose: _closeTrapWalkthrough,
                ),
              RepertoireStatusBar(
                tree: _generatedTree,
                trapCount: _traps.length,
                lineCount: _controller.repertoireLines.length,
                coveragePercent: _coverageResult?.coveragePercent,
                findingsCount: _auditResult?.activeFindingCount ?? 0,
                jobsStatus: _isGenerating
                    ? (_isGenerationPaused ? 'paused' : 'running')
                    : _isAuditing
                        ? 'auditing'
                        : null,
                onFindingsTap: _openFindingsDialog,
                onJobsTap: _openJobsDialog,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── New layout builders (Lichess-inspired) ──────────────────────────

  Widget _buildWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBoardZone(),
        _verticalZoneDivider(),
        Expanded(child: _buildToolsColumn()),
      ],
    );
  }

  Widget _buildCompactLayout() {
    return Column(
      children: [
        Expanded(
          flex: 4,
          child: _buildBoardZone(),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(
          flex: 5,
          child: _buildToolsColumn(),
        ),
      ],
    );
  }

  Widget _buildBoardZone() {
    return BoardZone(
      boardPreview: _boardPreview,
      fen: _controller.fen,
      positionFromFen: _positionFromFen,
      boardFlipped: _boardFlipped,
      isGenerating: _isGenerating,
      isGenerationPaused: _isGenerationPaused,
      onMove: _handleMove,
      onPause: () => _generationTabKey.currentState?.togglePause(),
      onResume: () => _generationTabKey.currentState?.togglePause(),
      onCancel: () => _generationTabKey.currentState?.cancelGeneration(),
      annotations: _buildBoardAnnotations(),
    );
  }

  /// Build board annotations from audit findings at the current position.
  ///
  /// Uses the dartchess library to resolve SAN moves to origin/dest squares
  /// for drawing arrows. Limited to 6 annotations to avoid visual clutter.
  List<BoardAnnotation> _buildBoardAnnotations() {
    final result = _auditResult;
    if (result == null) return const [];

    final currentFen = _controller.fen;
    final fenPrefix = currentFen.split(' ').take(4).join(' ');

    final relevant = result.findings.where((f) {
      if (f.dismissed) return false;
      final fFenPrefix = f.fen.split(' ').take(4).join(' ');
      return fFenPrefix == fenPrefix;
    }).toList();

    if (relevant.isEmpty) return const [];

    final annotations = <BoardAnnotation>[];
    const maxAnnotations = 6;

    Position? pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(currentFen));
    } catch (_) {
      return const [];
    }

    for (final f in relevant) {
      if (annotations.length >= maxAnnotations) break;

      final (brush, san) = switch (f.type) {
        AuditFindingType.mistake => (AnnotationBrush.red, f.ourMove),
        AuditFindingType.inaccuracy => (AnnotationBrush.yellow, f.ourMove),
        AuditFindingType.missingResponse => (AnnotationBrush.blue, f.missingMove),
        _ => (AnnotationBrush.green, null as String?),
      };

      if (san == null) continue;

      final squares = _sanToSquares(pos, san);
      if (squares != null) {
        annotations.add(BoardAnnotation(
          orig: squares.$1,
          dest: squares.$2,
          brush: brush,
        ));
      }
    }

    return annotations;
  }

  /// Resolve a SAN move to (from, to) square names using dartchess.
  (String, String)? _sanToSquares(Position pos, String san) {
    try {
      final move = pos.parseSan(san);
      if (move is NormalMove) {
        return (_squareName(move.from), _squareName(move.to));
      }
    } catch (_) {}
    return null;
  }

  String _squareName(int sq) {
    final file = String.fromCharCode(97 + (sq % 8));
    final rank = (sq ~/ 8) + 1;
    return '$file$rank';
  }

  /// Unified right pane: engine bar + expectimax bar + explorer + PGN + nav.
  Widget _buildToolsColumn() {
    return Column(
      children: [
        InlineEngineBar(
          fen: _controller.fen,
          isActive: _isPgnTabActive,
        ),
        const Divider(height: 1),
        InlineExpectimaxBar(
          controller: _controller,
          tree: _generatedTree,
          treeConfig: _generatedTreeConfig,
          fenMap: _generatedTreeFenMap,
          boardPreview: _boardPreview,
          coherenceResult: _coherenceService.result,
          isGenerating: _isGenerating,
          isGenerationPaused: _isGenerationPaused,
        ),
        const Divider(height: 1),
        ExplorerSection(
          controller: _controller,
          tree: _generatedTree,
          fenMap: _generatedTreeFenMap,
          boardPreview: _boardPreview,
          coherenceResult: _coherenceService.result,
          traps: _traps,
          coverageResult: _coverageResult,
          navigationStack: _navigationStack,
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: _buildPgnTab(),
          ),
        ),
        _buildNavControls(),
      ],
    );
  }

  Widget _buildNavControls() {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 20),
            onPressed: () => _controller.loadMoveSequence([]),
            tooltip: 'Go to start',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 24),
            onPressed: _controller.goBack,
            tooltip: 'Back (←)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 24),
            onPressed: _controller.goForward,
            tooltip: 'Forward (→)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _generateFromHere,
            icon: const Icon(Icons.add, size: 20),
            tooltip: 'Generate line from here',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.flip, size: 18),
            onPressed: () => setState(() => _boardFlipped = !_boardFlipped),
            tooltip: 'Flip board (F)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }

  Widget _buildJobsContent() {
    return ListenableBuilder(
      listenable: _jobManager,
      builder: (context, _) => JobsPanel(
        jobManager: _jobManager,
        isGenerating: _isGenerating,
        isGenerationPaused: _isGenerationPaused,
        isAuditing: _isAuditing,
        onOpenGenerationDialog: _openGenerationDialog,
        onPauseGeneration: () {
          _generationTabKey.currentState?.togglePause();
        },
        onResumeGeneration: () {
          _generationTabKey.currentState?.togglePause();
        },
        onCancelGeneration: () {
          _generationTabKey.currentState?.cancelGeneration();
        },
      ),
    );
  }

  Widget _buildFindingsContent() {
    return AuditFindingsPanel(
      result: _auditResult,
      liveFindings: _liveFindings,
      isAuditing: _isAuditing,
      onNavigateToPosition: (movePath) {
        _controller.loadMoveSequence(movePath);
      },
      onResultChanged: (updatedResult) {
        setState(() => _auditResult = updatedResult);
      },
    );
  }

  Widget _verticalZoneDivider() {
    return Container(width: 1, color: Colors.grey[700]);
  }

  void _openTrapWalkthrough({TrapLineInfo? startTrap}) {
    if (_trapIndex == null || _traps.isEmpty) return;
    setState(() {
      _trapWalkthroughVisible = true;
      _trapWalkthroughInitialTrap = startTrap;
      _trapWalkthroughSession++;
    });
  }

  void _closeTrapWalkthrough() {
    if (!_trapWalkthroughVisible) return;
    setState(() {
      _trapWalkthroughVisible = false;
      _trapWalkthroughInitialTrap = null;
    });
  }

  Future<void> _loadTraps(String filePath) async {
    final traps = await TrapExtractor.loadFromFile(filePath);
    if (mounted) {
      setState(() {
        _traps = traps ?? [];
        _trapIndex =
            _traps.isEmpty ? null : TrapIndexService(_traps);
      });
    }
  }

  Widget? _buildTrapNavigation() {
    final trapIndex = _trapIndex;
    if (trapIndex == null) return null;
    return TrapNavigationButtons(
      trapIndex: trapIndex,
      controller: _controller,
    );
  }


  Widget _buildPgnTab() {
    return PgnWithAnalysisPane(
      controller: _controller,
      tree: _controller.tree,
      currentPath: _controller.path,
      onJump: (path) => _controller.jump(path),
      onCommentChanged: (path, comment) =>
          _controller.setCommentAtPath(path, comment),
      onDelete: (path) => _controller.deleteAtPath(path),
      onPromote: (path) => _controller.promoteVariation(path),
      repertoireName: _controller.currentRepertoire?['name'] as String?,
      repertoireColor: _controller.isRepertoireWhite ? 'White' : 'Black',
      isEditingExistingLine: _controller.selectedPgnLine != null,
      onLineEdited: (updatedPgn) {
        _controller.updateSelectedLineContent(updatedPgn);
      },
      onLineSaved: (moves, title, pgn) {
        _controller.appendNewLine(moves, title, pgn);
      },
      onImportPgn: _importPgn,
      onReload: _reloadRepertoire,
      generatedTree: _generatedTree,
      treeConfig: _generatedTreeConfig,
      fenMap: _generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _coherenceService.result,
      isAnalysisActive: _isPgnTabActive,
      isGenerating: _isGenerating,
      isGenerationPaused: _isGenerationPaused,
      embedAnalysisDock: false,
      trapIndex: _trapIndex,
    );
  }



  void _onGeneratingChanged(bool generating) {
    if (!mounted) return;
    if (generating && _currentGenJob == null) {
      _currentGenJob = _jobManager.createJob(
        type: JobType.generation,
        label: _controller.currentRepertoire?['name'] as String? ??
            'Generation',
        subtreeFen: _controller.fen,
      );
      _currentGenJob!.updateStatus(JobStatus.running);
    } else if (!generating && _currentGenJob != null) {
      _currentGenJob!.updateStatus(JobStatus.completed);
      _currentGenJob = null;
    }
    setState(() {
      _isGenerating = generating;
      if (!generating) _isGenerationPaused = false;
    });
    context.read<AppState>().setRepertoireGenerating(generating);
    if (!generating) {
      final fp = _controller.currentRepertoire?['filePath'] as String?;
      if (fp != null) _loadTraps(fp);
    }
    // Jobs dialog opens automatically only if not already generating
    // (avoid spam on pause/resume cycles)
  }

  void _onPauseChanged(bool paused) {
    if (!mounted) return;
    _currentGenJob?.updateStatus(
        paused ? JobStatus.paused : JobStatus.running);
    setState(() => _isGenerationPaused = paused);
  }

  void _onTreeReset() {
    if (!mounted) return;
    _coherenceService.invalidate();
    setState(() {
      _generatedTree = null;
      _generatedTreeConfig = null;
      _generatedTreeFenMap = null;
    });
  }

  void _onTreeBuilt(dynamic tree) {
    if (!mounted) return;
    final t = tree as BuildTree;
    final fenMap = FenMap()..populate(t.root);
    TreeBuildConfig? config;
    if (t.configSnapshot.isNotEmpty) {
      try {
        config = TreeBuildConfig.fromJson(
          t.configSnapshot,
          startFen: t.root.fen,
        );
      } catch (e) {
        debugPrint('[RepertoireScreen] Tree operation failed: $e');
      }
    }
    setState(() {
      _generatedTree = t;
      _generatedTreeFenMap = fenMap;
      _generatedTreeConfig = config;
    });
    _runCoherence();
  }

  void _generateFromHere() {
    _openGenerationDialog();
  }

  void _selectLine(RepertoireLine line) {
    _controller.loadPgnLine(line);
  }

  Future<void> _renameLine(RepertoireLine line, String newTitle) async {
    final filePath = _controller.currentRepertoire?['filePath'] as String?;
    if (filePath == null) return;

    final service = RepertoireService();
    final success = await service.updateLineTitle(filePath, line.id, newTitle);

    if (success) {
      await _controller.loadRepertoire();
    } else {
      if (mounted) {
        showAppSnackBar(context, AppMessages.renameLineFailed, isError: true);
      }
    }
  }

  // --- HELPER METHODS ---

  /// Paste a FEN position from clipboard (Ctrl+Shift+V)
  Future<void> _pastePositionFromClipboard() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData == null || clipboardData.text == null) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardEmpty);
        }
        return;
      }

      final fen = clipboardData.text!.trim();
      if (fen.isEmpty) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardEmpty);
        }
        return;
      }

      final success = _controller.setPositionFromFen(fen);
      if (!success && mounted) {
        showAppSnackBar(context, AppMessages.invalidFen);
      }
    } catch (e) {
      debugPrint('Clipboard read failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.clipboardReadFailed,
            isError: true);
      }
    }
  }

  // --- METHODS (Now simple calls to the controller) ---

  Future<void> _showRepertoireSelection() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (context) => const RepertoireSelectionScreen(),
      ),
    );

    if (result != null && mounted) {
      await _controller.setRepertoire(result);
    }
    _reclaimFocus();
  }

  Future<void> _reloadRepertoire() async {
    // Tell the controller to reload
    await _controller.loadRepertoire();
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;
    _controller.userPlayedMove(move.san);
  }

  Position _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return _controller.position;
    }
  }

  Future<void> _showCoverageCalculator() async {
    final config = await showCoverageConfigDialog(context);
    if (config == null || !mounted) return;

    if (_controller.openingTree == null) {
      showAppSnackBar(context, 'No repertoire tree loaded');
      return;
    }

    setState(() {
      _isCoverageRunning = true;
      _coverageResult = null;
      _coverageProgress = 0.0;
      _coverageProgressMessage = 'Starting analysis...';
    });

    // Coverage results will be visible in the status bar

    final service = CoverageService(
      database: config.database,
      ratings: config.ratingsString,
      speeds: config.speedsString,
      useMaia: config.useMaia,
      maiaElo: config.maiaElo,
    );

    try {
      final result = await service.analyzeOpeningTree(
        _controller.openingTree!,
        targetPercent: config.targetPercent,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onProgress: (message, progress) {
          if (mounted) {
            setState(() {
              _coverageProgressMessage = message;
              _coverageProgress = progress;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _coverageResult = result;
          _isCoverageRunning = false;
          _coverageProgress = null;
          _coverageProgressMessage = null;
        });
        showAppSnackBar(
          context,
          'Coverage: ${result.coveragePercent.toStringAsFixed(1)}% covered, '
          '${result.tooShallowLeaves.length} shallow, '
          '${result.tooDeepLeaves.length} deep, '
          '${result.unaccountedMoves.length} unaccounted moves',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCoverageRunning = false;
          _coverageProgress = null;
          _coverageProgressMessage = null;
        });
        showAppSnackBar(context, 'Coverage analysis failed: $e');
      }
    }
  }

  void _runCoherence() {
    if (_controller.repertoireLines.length < 5) return;
    _coherenceService.compute(
      lines: _controller.repertoireLines,
      playAsWhite: _controller.isRepertoireWhite,
    );
    _coherenceService.addListener(_onCoherenceUpdated);
  }

  void _onCoherenceUpdated() {
    if (mounted) setState(() {});
    _coherenceService.removeListener(_onCoherenceUpdated);
  }

  void _trainRepertoire() {
    if (_controller.currentRepertoire == null) return;
    final filePath = _controller.currentRepertoire!['filePath'] as String?;
    if (filePath == null) return;

    context.read<AppState>().switchToTrainer(repertoirePath: filePath);
  }

  Future<void> _importPgn() async {
    final result = await showPgnImportDialog(
      context,
      title: 'Import PGN into Repertoire',
      confirmLabel: 'Add to Repertoire',
    );
    if (result == null || !mounted) return;

    final added = await _controller.importPgnContent(result.pgnContent);
    if (!mounted) return;

    showAppSnackBar(
      context,
      'Added $added line${added == 1 ? '' : 's'} to repertoire.',
    );
  }
}

