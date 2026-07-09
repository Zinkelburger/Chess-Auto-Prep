/// Manual puzzle creation flow: set up a position, play the solution,
/// annotate, and save into a chosen puzzle set.
///
/// Pushed as a route from the Tactics panel (or via the cross-mode
/// "Make puzzle from this position" hooks).  Receives the *live*
/// [TacticsDatabase] so saves land in the provider-owned instance.
library;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../constants/ui_breakpoints.dart';
import '../core/puzzle_creator_controller.dart';
import '../models/tactics_position.dart';
import '../services/tactics_database.dart';
import '../utils/app_messages.dart';
import '../widgets/board_editor/board_editor_widget.dart';
import '../widgets/board_editor/piece_palette.dart';
import '../widgets/board_editor/position_setup_panel.dart';
import '../widgets/chess_board_widget.dart';

class PuzzleCreatorScreen extends StatefulWidget {
  final TacticsDatabase database;
  final String? initialFen;

  const PuzzleCreatorScreen({
    super.key,
    required this.database,
    this.initialFen,
  });

  /// Push the creator; resolves to the saved puzzle (or null if abandoned).
  static Future<TacticsPosition?> push(
    BuildContext context, {
    required TacticsDatabase database,
    String? initialFen,
  }) {
    return Navigator.of(context).push<TacticsPosition>(
      MaterialPageRoute(
        builder: (_) => PuzzleCreatorScreen(
          database: database,
          initialFen: initialFen,
        ),
      ),
    );
  }

  @override
  State<PuzzleCreatorScreen> createState() => _PuzzleCreatorScreenState();
}

class _PuzzleCreatorScreenState extends State<PuzzleCreatorScreen> {
  late final PuzzleCreatorController _creator;

  final _noteCtrl = TextEditingController();
  final _whiteCtrl = TextEditingController();
  final _blackCtrl = TextEditingController();
  int _rating = 0;
  late String _targetSet;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _creator = PuzzleCreatorController(initialFen: widget.initialFen);
    _creator.addListener(_onChanged);
    // An external set (study under review) is not a named set the creator
    // can append to; fall back to a real set.
    _targetSet = widget.database.isExternalSet
        ? (widget.database.availableSets.firstOrNull?.name ??
            TacticsDatabase.defaultSetName)
        : widget.database.activeSetName;
  }

  @override
  void dispose() {
    _creator.removeListener(_onChanged);
    _creator.dispose();
    _noteCtrl.dispose();
    _whiteCtrl.dispose();
    _blackCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<String> get _setNames {
    final names = widget.database.availableSets.map((s) => s.name).toList();
    if (!names.contains(_targetSet)) names.insert(0, _targetSet);
    return names;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final puzzle = _creator.buildPuzzle(
        note: _noteCtrl.text.trim(),
        rating: _rating,
        gameWhite: _whiteCtrl.text.trim(),
        gameBlack: _blackCtrl.text.trim(),
      );
      final added =
          await widget.database.addPositionToSet(_targetSet, puzzle);
      if (!mounted) return;
      if (added) {
        Navigator.of(context).pop(puzzle);
      } else {
        showAppSnackBar(
            context, 'A puzzle with this position already exists in "$_targetSet".',
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_creator.step) {
          CreatorStep.setup => 'New puzzle — set up position',
          CreatorStep.recordSolution => 'New puzzle — play the solution',
          CreatorStep.details => 'New puzzle — details',
        }),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < kCompactBreakpoint;
          final board = _buildBoardPane();
          final panel = Padding(
            padding: const EdgeInsets.all(16),
            child: _buildSidePanel(),
          );
          return compact
              ? Column(children: [
                  Expanded(flex: 5, child: board),
                  const Divider(height: 1),
                  Expanded(flex: 4, child: panel),
                ])
              : Row(children: [
                  Expanded(flex: 5, child: board),
                  Container(width: 1, color: Colors.grey[700]),
                  Expanded(flex: 4, child: panel),
                ]);
        },
      ),
    );
  }

  Widget _buildBoardPane() {
    final editing = _creator.step == CreatorStep.setup;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: editing
                    ? BoardEditorWidget(controller: _creator.editor)
                    : ChessBoardWidget(
                        position: _creator.currentPosition!,
                        // Solver's perspective while recording/reviewing.
                        flipped: _creator.solverSide == Side.black,
                        enableUserMoves:
                            _creator.step == CreatorStep.recordSolution,
                        onMove: (move) {
                          if (!_creator.playMoveSan(move.san)) {
                            showAppSnackBar(context, 'Move rejected.',
                                isError: true);
                          }
                        },
                      ),
              ),
            ),
          ),
          if (editing) ...[
            const SizedBox(height: 8),
            PiecePalette(controller: _creator.editor),
          ],
        ],
      ),
    );
  }

  Widget _buildSidePanel() {
    return switch (_creator.step) {
      CreatorStep.setup => PositionSetupPanel(
          controller: _creator.editor,
          actionLabel: 'Record solution',
          onAction: (_) => _creator.startRecording(),
        ),
      CreatorStep.recordSolution => _buildRecordingPanel(),
      CreatorStep.details => _buildDetailsPanel(),
    };
  }

  Widget _buildRecordingPanel() {
    final theme = Theme.of(context);
    final solver = _creator.solverSide == Side.white ? 'White' : 'Black';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Play the solution on the board.\n'
          '$solver (the solver) moves first; include opponent replies for '
          'multi-move puzzles.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Text('Solution', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Expanded(
          child: _creator.solutionSan.isEmpty
              ? Text('No moves yet.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
              : SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final (i, san) in _creator.solutionSan.indexed)
                        Chip(
                          label: Text(
                            san,
                            style: TextStyle(
                              fontSize: 12,
                              // Solver moves (even indices) bold.
                              fontWeight: i.isEven
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.undo, size: 16),
              label: const Text('Undo move'),
              onPressed:
                  _creator.solutionSan.isEmpty ? null : _creator.undoLastMove,
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _creator.backToSetup,
              child: const Text('Back to setup'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _creator.solutionSan.isEmpty
                  ? null
                  : _creator.finishRecording,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDetailsPanel() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Solution: ${_creator.solutionSan.join(' ')}',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _noteCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Notes',
              hintText: 'Why does this work? What is the idea?',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _whiteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'White (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _blackCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Black (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Rating', style: theme.textTheme.labelLarge),
              const SizedBox(width: 8),
              for (int star = 1; star <= 5; star++)
                IconButton(
                  icon: Icon(
                    star <= _rating ? Icons.star : Icons.star_border,
                    size: 20,
                    color: Colors.amber,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(
                      () => _rating = star == _rating ? 0 : star),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Save to set', style: theme.textTheme.labelLarge),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: _targetSet,
                  isExpanded: true,
                  isDense: true,
                  items: [
                    for (final name in _setNames)
                      DropdownMenuItem(value: name, child: Text(name)),
                  ],
                  onChanged: (name) {
                    if (name != null) setState(() => _targetSet = name);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton(
                onPressed: _creator.backToRecording,
                child: const Text('Back'),
              ),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save puzzle'),
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
