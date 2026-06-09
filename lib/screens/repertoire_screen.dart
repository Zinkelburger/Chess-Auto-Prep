/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/repertoire_controller.dart';
import '../core/generation_session_controller.dart';
import '../core/audit_session_controller.dart';
import '../core/coverage_controller.dart';
import '../models/engine_settings.dart';
import '../models/repertoire_line.dart';
import '../services/repertoire_service.dart';
import '../utils/app_messages.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/coverage_calculator_widget.dart';
import '../widgets/pgn_with_analysis_pane.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/generation_config_dialog.dart';
import '../widgets/layout/board_zone.dart';
import '../widgets/layout/bottom_pane.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/layout/empty_state_placeholder.dart';
import '../widgets/layout/jobs_panel.dart';
import '../widgets/repertoire_lines_browser.dart';
import '../constants/ui_breakpoints.dart';
import '../widgets/repertoire/repertoire_toolbar.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/engine/inline_expectimax_bar.dart';
import '../services/jobs/repertoire_job.dart';
import '../features/audit/models/audit_finding.dart';
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

class _RepertoireScreenState extends State<RepertoireScreen> {
  late final RepertoireController _controller;
  final GenerationSessionController _generationController =
      GenerationSessionController();
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  final AuditSessionController _auditController = AuditSessionController();
  final GlobalKey<BottomPaneState> _bottomPaneKey =
      GlobalKey<BottomPaneState>();
  bool _isCompactLayout = false;

  final JobManager _jobManager = JobManager.instance;

  final BoardPreviewController _boardPreview = BoardPreviewController();
  final NavigationStack _navigationStack = NavigationStack();

  bool _boardFlipped = false;

  /// Currently previewed missing-move finding (ephemeral board state).
  AuditFinding? _ephemeralFinding;

  /// FEN with the missing move played (ephemeral, not saved to tree).
  String? _ephemeralFen;

  List<TrapLineInfo> _traps = [];
  TrapIndexService? _trapIndex;
  bool _trapWalkthroughVisible = false;
  TrapLineInfo? _trapWalkthroughInitialTrap;
  int _trapWalkthroughSession = 0;

  final CoverageController _coverageController = CoverageController();

  String? _lastRepertoireId;

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    _controller = RepertoireController();
    _controller.addListener(_onRepertoireChanged);
    _generationController.addListener(_onGenerationChanged);
    _auditController.addListener(_onAuditChanged);
    _coverageController.addListener(_onCoverageChanged);

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

  void _openBottomPane(BottomPaneTab tab) {
    _bottomPaneKey.currentState?.open(tab);
  }

  void _toggleBottomPane(BottomPaneTab tab) {
    _bottomPaneKey.currentState?.toggle(tab);
  }

  void _closeBottomPane() {
    _bottomPaneKey.currentState?.close();
  }

  void _openGenerationDialog() {
    showGenerationConfigDialog(
      context,
      fen: _controller.fen,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      currentRepertoire: _controller.currentRepertoire,
      currentMoveSequence: _controller.currentMoveSequence,
      generationTabKey: _generationTabKey,
      generationController: _generationController,
      onLineSaved: (moves, title, pgn) {
        _controller.appendNewLine(moves, title, pgn);
      },
    );
  }

  void _openAuditDialog({bool forceConfig = false}) {
    if (!forceConfig) {
      if (_auditController.isAuditing || _auditController.hasResults) {
        _openBottomPane(BottomPaneTab.findings);
        return;
      }
    }
    _launchAuditConfig();
  }

  String? get _repertoireFilePath =>
      _controller.currentRepertoire?['filePath'] as String?;

  void _launchAuditConfig() {
    final ac = _auditController;
    showAuditConfigDialog(
      context,
      openingTree: _controller.openingTree,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      currentFen: _controller.fen,
      currentMoveSequence: _controller.currentMoveSequence,
      repertoireFilePath: _repertoireFilePath,
      auditService: ac.service,
      onConfigChanged: ac.onConfigChanged,
      onAuditingChanged: (auditing) {
        if (!mounted) return;
        ac.onAuditingChanged(
          auditing,
          _jobManager,
          _controller.currentRepertoire?['name'] as String? ?? 'Audit',
        );
        if (auditing) _openBottomPane(BottomPaneTab.findings);
      },
      onResultReady: (result) {
        if (!mounted) return;
        ac.onResultReady(result, _repertoireFilePath);
      },
      onLiveFinding: (finding) {
        if (!mounted) return;
        ac.onLiveFinding(finding);
      },
      onProgress: (checked, total) {
        if (!mounted) return;
        ac.onProgress(checked, total);
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

  bool _navigatingToFinding = false;

  void _onRepertoireChanged() {
    if (!mounted) return;

    String? newRepertoireId;
    setState(() {
      // Clear ephemeral state when the user navigates normally (not via finding).
      if (!_navigatingToFinding && _ephemeralFinding != null) {
        _ephemeralFinding = null;
        _ephemeralFen = null;
      }

      if (_controller.currentRepertoire != null && !_controller.isLoading) {
        final currentId =
            _controller.currentRepertoire!['filePath'] as String?;
        if (currentId != null && currentId != _lastRepertoireId) {
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite;
          _generationController.clearTree();
          _coverageController.clear();
          EngineSettings().probabilityStartMoves = _controller.rootMoves;
          _loadTraps(currentId);
          newRepertoireId = currentId;
        }

        if (_controller.needsColorSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showColorSelectionDialog();
          });
        }
      }
    });

    if (newRepertoireId != null) {
      _auditController.tryRestore(newRepertoireId!);
    }
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
    if (_auditController.isAuditing) {
      _auditController.saveProgress(_repertoireFilePath);
    }
    _focusNode.dispose();
    _boardPreview.dispose();
    _coverageController.removeListener(_onCoverageChanged);
    _coverageController.dispose();
    _auditController.removeListener(_onAuditChanged);
    _auditController.dispose();
    _generationController.removeListener(_onGenerationChanged);
    _generationController.dispose();
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

    // '1' key — toggle Jobs in bottom pane
    if (event.logicalKey == LogicalKeyboardKey.digit1 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _toggleBottomPane(BottomPaneTab.jobs);
      return KeyEventResult.handled;
    }

    // '2' key — toggle Findings in bottom pane
    if (event.logicalKey == LogicalKeyboardKey.digit2 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _toggleBottomPane(BottomPaneTab.findings);
      return KeyEventResult.handled;
    }

    // '3' key — toggle Lines in bottom pane
    if (event.logicalKey == LogicalKeyboardKey.digit3 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _toggleBottomPane(BottomPaneTab.lines);
      return KeyEventResult.handled;
    }

    // Escape — collapse bottom pane
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final pane = _bottomPaneKey.currentState;
      if (pane != null && !pane.isCollapsed) {
        _closeBottomPane();
        return KeyEventResult.handled;
      }
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
        isGenerating: _generationController.isGenerating,
        isGenerationPaused: _generationController.isPaused,
        showTrainButton: true,
        showSelectRepertoireAction: true,
        generationLocked: _generationController.isGenerating,
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
              _buildBottomPane(),
              RepertoireStatusBar(
                findingsCount: _auditController.activeFindingCount,
                jobsStatus: _generationController.isGenerating
                    ? (_generationController.isPaused ? 'Paused' : 'Generating...')
                    : _auditController.isAuditing
                        ? 'Auditing...'
                        : null,
                onFindingsTap: () =>
                    _toggleBottomPane(BottomPaneTab.findings),
                onJobsTap: () =>
                    _toggleBottomPane(BottomPaneTab.jobs),
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
    return Column(
      children: [
        Expanded(
          child: BoardZone(
            boardPreview: _boardPreview,
            fen: _ephemeralFen ?? _controller.fen,
            positionFromFen: _positionFromFen,
            boardFlipped: _boardFlipped,
            isGenerating: _generationController.isGenerating,
            isGenerationPaused: _generationController.isPaused,
            onMove: _handleMove,
            onPause: _generationController.pauseBuild,
            onResume: _generationController.resumeBuild,
            onCancel: _generationController.cancelBuild,
            annotations: _buildBoardAnnotations(),
          ),
        ),
        if (_ephemeralFinding != null) _buildEphemeralBar(),
      ],
    );
  }

  Widget _buildEphemeralBar() {
    final finding = _ephemeralFinding!;
    final move = finding.missingMove ?? '?';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(30),
        border: Border(top: BorderSide(color: Colors.blue.withAlpha(80))),
      ),
      child: Row(
        children: [
          const Icon(Icons.visibility_off_outlined, size: 14,
              color: Colors.blue),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Missing: $move (preview)',
              style: const TextStyle(fontSize: 12, color: Colors.blue),
            ),
          ),
          TextButton.icon(
            onPressed: _createNewLineFromEphemeral,
            icon: const Icon(Icons.add, size: 14),
            label: const Text('New line from here',
                style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: Colors.blue,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 14, color: Colors.grey),
            onPressed: () {
              setState(() {
                _ephemeralFinding = null;
                _ephemeralFen = null;
              });
            },
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
    );
  }

  /// Build board annotations from audit findings at the current position.
  ///
  /// Uses the dartchess library to resolve SAN moves to origin/dest squares
  /// for drawing arrows. Limited to 6 annotations to avoid visual clutter.
  List<BoardAnnotation> _buildBoardAnnotations() {
    final result = _auditController.result;
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

  /// Unified right pane: engine + expectimax (horizontal) + PGN + nav.
  Widget _buildToolsColumn() {
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InlineEngineBar(
                  fen: _controller.fen,
                  isActive: true,
                ),
              ),
              VerticalDivider(width: 1, thickness: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: InlineExpectimaxBar(
                  controller: _controller,
                  tree: _generationController.generatedTree,
                  treeConfig: _generationController.generatedTreeConfig,
                  fenMap: _generationController.generatedTreeFenMap,
                  boardPreview: _boardPreview,
                  coherenceResult: _generationController.coherenceService.result,
                  isGenerating: _generationController.isGenerating,
                  isGenerationPaused: _generationController.isPaused,
                ),
              ),
            ],
          ),
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
      height: 28,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 16),
            onPressed: () => _controller.loadMoveSequence([]),
            tooltip: 'Go to start',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: _controller.goBack,
            tooltip: 'Back (←)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _controller.goForward,
            tooltip: 'Forward (→)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _generateFromHere,
            icon: const Icon(Icons.add, size: 16),
            tooltip: 'Generate line from here',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.flip, size: 14),
            onPressed: () => setState(() => _boardFlipped = !_boardFlipped),
            tooltip: 'Flip board (F)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
        isGenerating: _generationController.isGenerating,
        isGenerationPaused: _generationController.isPaused,
        isAuditing: _auditController.isAuditing,
        isAuditPaused: _auditController.isPaused,
        auditNodesChecked: _auditController.nodesChecked,
        auditTotalNodes: _auditController.totalNodes,
        lastAuditConfig: _auditController.lastConfig,
        onOpenGenerationDialog: _openGenerationDialog,
        onPauseAudit: _auditController.pause,
        onResumeAudit: _auditController.resume,
        onCancelAudit: () => _auditController.cancel(_repertoireFilePath),
        onPauseGeneration: _generationController.pauseBuild,
        onResumeGeneration: _generationController.resumeBuild,
        onCancelGeneration: _generationController.cancelBuild,
      ),
    );
  }

  Widget _buildFindingsContent() {
    final ac = _auditController;
    return AuditFindingsPanel(
      result: ac.result,
      liveFindings: ac.liveFindings,
      isAuditing: ac.isAuditing,
      auditNodesChecked: ac.nodesChecked,
      auditTotalNodes: ac.totalNodes,
      onFindingSelected: _onFindingSelected,
      onResultChanged: (updatedResult) {
        ac.onResultChanged(updatedResult, _repertoireFilePath);
      },
      onRerunAudit: () => _openAuditDialog(forceConfig: true),
      interruptedSnapshot: ac.interruptedSnapshot,
      onResumeAudit: ac.interruptedSnapshot != null ? _resumeInterruptedAudit : null,
      onStartFreshAudit: ac.interruptedSnapshot != null ? _startFreshAudit : null,
    );
  }

  void _resumeInterruptedAudit() {
    final snap = _auditController.interruptedSnapshot;
    if (snap == null) return;
    final tree = _controller.openingTree;
    if (tree == null) return;
    _openBottomPane(BottomPaneTab.findings);
    _auditController.launchResume(
      snapshot: snap,
      tree: tree,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      jobManager: _jobManager,
      repertoireLabel: _controller.currentRepertoire?['name'] as String?,
      repertoireFilePath: _repertoireFilePath,
    );
  }

  void _startFreshAudit() {
    _auditController.startFresh();
    _openAuditDialog(forceConfig: true);
  }

  void _onFindingSelected(AuditFinding finding) {
    _navigatingToFinding = true;
    _controller.navigateToLineMove(finding.movePath);
    _navigatingToFinding = false;

    if (finding.type == AuditFindingType.missingResponse &&
        finding.missingMove != null) {
      try {
        final parentFen = _controller.fen;
        final pos = Chess.fromSetup(Setup.parseFen(parentFen));
        final move = pos.parseSan(finding.missingMove!);
        if (move != null) {
          final after = pos.play(move);
          setState(() {
            _ephemeralFinding = finding;
            _ephemeralFen = after.fen;
          });
          return;
        }
      } catch (_) {}
    }

    if (_ephemeralFinding != null) {
      setState(() {
        _ephemeralFinding = null;
        _ephemeralFen = null;
      });
    }
  }

  void _createNewLineFromEphemeral() {
    final finding = _ephemeralFinding;
    if (finding == null || finding.missingMove == null) return;

    final lineMoves = [...finding.movePath, finding.missingMove!];

    setState(() {
      _ephemeralFinding = null;
      _ephemeralFen = null;
    });

    _controller.navigateToLineMove(lineMoves);
  }

  Widget _buildLinesContent() {
    return RepertoireLinesBrowser(
      lines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      coverageResult: _coverageController.result,
      isCoverageRunning: _coverageController.isRunning,
      coverageProgress: _coverageController.progress,
      coverageProgressMessage: _coverageController.progressMessage,
      tree: _generationController.generatedTree,
      fenMap: _generationController.generatedTreeFenMap,
      traps: _traps,
      coherenceResult: _generationController.coherenceService.result,
      navigationStack: _navigationStack,
      onLineSelected: _selectLine,
      onLineRenamed: _renameLine,
      onCoveragePressed: _showCoverageCalculator,
      onNavigateToPosition: (moves) {
        _controller.loadMoveSequence(moves);
      },
    );
  }

  Widget _buildBottomPane() {
    return ListenableBuilder(
      listenable: _jobManager,
      builder: (context, _) => BottomPane(
        key: _bottomPaneKey,
        findingsContent: _buildFindingsContent(),
        jobsContent: _buildJobsContent(),
        linesContent: _buildLinesContent(),
        findingsBadge: _auditController.activeFindingCount,
        jobsBadge: _jobManager.activeJobs.length,
        linesBadge: _controller.repertoireLines.length,
      ),
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
      onMakeMainLine: (path) => _controller.makeMainLine(path),
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
      generatedTree: _generationController.generatedTree,
      treeConfig: _generationController.generatedTreeConfig,
      fenMap: _generationController.generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _generationController.coherenceService.result,
      isAnalysisActive: true,
      isGenerating: _generationController.isGenerating,
      isGenerationPaused: _generationController.isPaused,
      embedAnalysisDock: false,
      trapIndex: _trapIndex,
    );
  }



  void _onGenerationChanged() {
    if (!mounted) return;
    final ctrl = _generationController;

    // Job tracking
    if (ctrl.isGenerating && ctrl.currentJob == null) {
      ctrl.currentJob = _jobManager.createJob(
        type: JobType.generation,
        label: _controller.currentRepertoire?['name'] as String? ??
            'Generation',
        subtreeFen: _controller.fen,
      );
      ctrl.currentJob!.updateStatus(JobStatus.running);
      _openBottomPane(BottomPaneTab.jobs);
    }

    context.read<AppState>().setRepertoireGenerating(ctrl.isGenerating);

    // Run coherence when tree is built
    if (ctrl.generatedTree != null) {
      _runCoherence();
    }

    if (!ctrl.isGenerating) {
      final fp = _controller.currentRepertoire?['filePath'] as String?;
      if (fp != null) _loadTraps(fp);
    }

    setState(() {});
  }

  void _onAuditChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onCoverageChanged() {
    if (!mounted) return;
    setState(() {});
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

    final tree = _controller.openingTree;
    if (tree == null) {
      showAppSnackBar(context, 'No repertoire tree loaded');
      return;
    }

    try {
      final result = await _coverageController.calculate(
        config: config,
        tree: tree,
        isWhiteRepertoire: _controller.isRepertoireWhite,
      );
      if (result != null && mounted) {
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
        showAppSnackBar(context, 'Coverage analysis failed: $e');
      }
    }
  }

  void _runCoherence() {
    if (_controller.repertoireLines.length < 5) return;
    final cs = _generationController.coherenceService;
    cs.compute(
      lines: _controller.repertoireLines,
      playAsWhite: _controller.isRepertoireWhite,
    );
    cs.addListener(_onCoherenceUpdated);
  }

  void _onCoherenceUpdated() {
    if (mounted) setState(() {});
    _generationController.coherenceService.removeListener(_onCoherenceUpdated);
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

