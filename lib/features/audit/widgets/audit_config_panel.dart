/// Chapter audit configuration route: sources, scope and validated thresholds.
/// Delegates execution to the session controller through onStart.
library;

import 'package:provider/provider.dart';

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../settings/controllers/bulk_analysis_settings.dart';
import 'package:path/path.dart' as p;

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/engine/engine_gate.dart';
import '../services/audit_config.dart';
import '../../../widgets/labeled_toggle.dart';
import '../../../utils/movetext_builder.dart';
import 'hunt_controls.dart';

class AuditConfigPanel extends StatefulWidget {
  final OpeningGraph? openingTree;
  final bool isWhiteRepertoire;
  final String currentFen;
  final List<String> currentMoveSequence;
  final String? repertoireFilePath;

  /// Configuration only: the session controller owns the run after this route closes.
  final void Function(AuditConfig config, String? startFen) onStart;

  const AuditConfigPanel({
    super.key,
    required this.openingTree,
    required this.isWhiteRepertoire,
    required this.currentFen,
    required this.currentMoveSequence,
    this.repertoireFilePath,
    required this.onStart,
  });

  @override
  State<AuditConfigPanel> createState() => AuditConfigPanelState();
}

class AuditConfigPanelState extends State<AuditConfigPanel> {
  final TextEditingController _mistakeCtrl = TextEditingController(text: '100');
  final TextEditingController _inaccuracyCtrl = TextEditingController(
    text: '40',
  );
  final TextEditingController _minGamesCtrl = TextEditingController(text: '50');
  final TextEditingController _minMaiaProbCtrl = TextEditingController(
    text: '0.10',
  );
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '30');
  final TextEditingController _maiaEloCtrl = TextEditingController(
    text: '2200',
  );
  final TextEditingController _strongReplyWindowCtrl = TextEditingController(
    text: '50',
  );

  // Mothballed: Lichess Explorer disabled.
  final bool _useLichessDb = false;
  bool _useChessDb = true;
  bool _auditSubtreeOnly = false;

  /// PGN file paths for repertoire-clash checking.
  final List<String> _clashPgnPaths = [];

  bool _isAuditing = false;
  String? _validationError;

  bool get isAuditing => _isAuditing;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _mistakeCtrl.dispose();
    _inaccuracyCtrl.dispose();
    _minGamesCtrl.dispose();
    _minMaiaProbCtrl.dispose();
    _maxPlyCtrl.dispose();
    _maiaEloCtrl.dispose();
    _strongReplyWindowCtrl.dispose();
    super.dispose();
  }

  // ── Audit lifecycle ──────────────────────────────────────────────────

  AuditConfig _buildConfig() {
    return AuditConfig(
      mistakeThresholdCp: int.tryParse(_mistakeCtrl.text) ?? 100,
      inaccuracyThresholdCp: int.tryParse(_inaccuracyCtrl.text) ?? 40,
      minGames: int.tryParse(_minGamesCtrl.text) ?? 50,
      minMaiaProb: double.tryParse(_minMaiaProbCtrl.text) ?? 0.10,
      evalDepth: context.read<BulkAnalysisSettings>().depth,
      maxPly: int.tryParse(_maxPlyCtrl.text) ?? 30,
      maiaElo: int.tryParse(_maiaEloCtrl.text) ?? 2200,
      useStockfish: true,
      useLichessDb: _useLichessDb,
      useMaia: true,
      useChessDb: _useChessDb,
      strongReplyWindowCp: int.tryParse(_strongReplyWindowCtrl.text) ?? 50,
      clashPgnPaths: List.unmodifiable(_clashPgnPaths),
    );
  }

  Future<void> _addClashPgns() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
    );
    if (files.isEmpty) return;
    if (!mounted) return;
    setState(() {
      for (final file in files) {
        final filePath = file.path;
        if (filePath != null && !_clashPgnPaths.contains(filePath)) {
          _clashPgnPaths.add(filePath);
        }
      }
    });
  }

  void _startAudit() {
    if (_isAuditing || widget.openingTree == null) return;
    final mistake = int.tryParse(_mistakeCtrl.text);
    final inaccuracy = int.tryParse(_inaccuracyCtrl.text);
    final depth = int.tryParse(_maxPlyCtrl.text);
    final rating = int.tryParse(_maiaEloCtrl.text);
    final probability = double.tryParse(_minMaiaProbCtrl.text);
    final replyWindow = int.tryParse(_strongReplyWindowCtrl.text);
    if (mistake == null ||
        inaccuracy == null ||
        inaccuracy < 0 ||
        mistake <= inaccuracy ||
        depth == null ||
        depth < 1 ||
        rating == null ||
        rating < 1100 ||
        rating > 2900 ||
        probability == null ||
        !probability.isFinite ||
        probability < 0 ||
        probability > 1 ||
        replyWindow == null ||
        replyWindow < 0) {
      setState(
        () => _validationError =
            'Use positive whole-number depths, a Maia rating from 1100–2900, '
            'probability from 0–1, and a mistake threshold above the inaccuracy threshold.',
      );
      return;
    }
    if (!EngineGate.ensureAvailable(context)) return;
    setState(() {
      _isAuditing = true;
      _validationError = null;
    });
    widget.onStart(
      _buildConfig(),
      _auditSubtreeOnly ? widget.currentFen : null,
    );
  }

  // ── Build ────────────────────────────────────────────────────────────

  bool _showAdvanced = false;

  @override
  Widget build(BuildContext context) {
    final scopeLabel =
        _auditSubtreeOnly && widget.currentMoveSequence.isNotEmpty
        ? 'Subtree from ${_moveSequenceLabel(widget.currentMoveSequence)}'
        : 'Current chapter';

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Scope toggle + label
              Row(
                children: [
                  const Icon(
                    Icons.account_tree_outlined,
                    size: 14,
                    color: AppColors.onSurfaceMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(scopeLabel, style: AppTextStyles.caption),
                  const Spacer(),
                  AppCheckbox(
                    label: 'Subtree only',
                    value: _auditSubtreeOnly,
                    onChanged: (v) {
                      if (!mounted) return;
                      setState(() => _auditSubtreeOnly = v);
                    },
                    enabled: !_isAuditing,
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Uses Stockfish + Maia (always on); ChessDB is optional.
              Row(
                children: [
                  const Icon(
                    Icons.memory,
                    size: 13,
                    color: AppColors.onSurfaceMuted,
                  ),
                  const SizedBox(width: 4),
                  const Text('Stockfish + Maia', style: AppTextStyles.caption),
                  const Spacer(),
                  AppCheckbox(
                    label: 'ChessDB replies',
                    value: _useChessDb,
                    onChanged: (v) {
                      if (!mounted) return;
                      setState(() => _useChessDb = v);
                    },
                    enabled: !_isAuditing,
                    tooltip:
                        'Flags uncovered opponent replies ChessDB scores close '
                        'to their best, played or not. Needs the network.',
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Key thresholds
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField(
                    _maxPlyCtrl,
                    'Max depth (half-moves)',
                    tooltip:
                        'How far into each line the audit walks, counted in '
                        'half-moves from the start position.',
                  ),
                  _numField(
                    _maiaEloCtrl,
                    'Maia rating',
                    tooltip:
                        'Playing strength of the Maia human model predicting '
                        'opponent replies.',
                  ),
                ],
              ),
              const SizedBox(height: 8),

              DisclosureHeader(
                label: 'More thresholds',
                expanded: _showAdvanced,
                onToggle: () {
                  if (!mounted) return;
                  setState(() => _showAdvanced = !_showAdvanced);
                },
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _numField(
                      _mistakeCtrl,
                      'Mistake threshold (centipawns)',
                      tooltip:
                          'Eval loss versus the engine best move for a '
                          'repertoire move to count as a mistake.',
                    ),
                    _numField(
                      _inaccuracyCtrl,
                      'Inaccuracy threshold (centipawns)',
                      tooltip:
                          'Eval loss versus the engine best move for a '
                          'repertoire move to count as an inaccuracy.',
                    ),
                    _numField(
                      _minMaiaProbCtrl,
                      'Minimum Maia probability',
                      tooltip:
                          'Opponent replies predicted below this probability '
                          '(0 to 1) are not checked.',
                    ),
                    _numField(
                      _strongReplyWindowCtrl,
                      'Strong reply window (centipawns)',
                      tooltip:
                          'An uncovered opponent reply is flagged when Stockfish '
                          'or ChessDB scores it within this many centipawns of '
                          'their best move.',
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),

              // Repertoire Clashes
              Row(
                children: [
                  const Icon(
                    Icons.menu_book_outlined,
                    size: 14,
                    color: AppColors.onSurfaceMuted,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Repertoire Clashes',
                    style: AppTextStyles.caption,
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 26,
                    child: TextButton.icon(
                      onPressed: _isAuditing ? null : _addClashPgns,
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Add PGN',
                        style: TextStyle(fontSize: 12),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
              if (_clashPgnPaths.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (int i = 0; i < _clashPgnPaths.length; i++)
                      InputChip(
                        label: Text(
                          p.basenameWithoutExtension(_clashPgnPaths[i]),
                          style: const TextStyle(fontSize: 12),
                        ),
                        deleteIcon: const Icon(Icons.close, size: 14),
                        onDeleted: _isAuditing
                            ? null
                            : () {
                                if (!mounted) return;
                                setState(() => _clashPgnPaths.removeAt(i));
                              },
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                  ],
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.only(left: 20),
                  child: Text(
                    'Check against book & course lines',
                    style: AppTextStyles.caption,
                  ),
                ),
              const SizedBox(height: 10),

              if (_validationError != null) ...[
                Text(
                  _validationError!,
                  style: const TextStyle(color: AppColors.danger),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                onPressed: _isAuditing || widget.openingTree == null
                    ? null
                    : _startAudit,
                icon: const Icon(Icons.policy_outlined, size: 18),
                label: Text(_isAuditing ? 'Starting…' : 'Start audit'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numField(
    TextEditingController ctrl,
    String label, {
    String? tooltip,
  }) => HuntNumberField(
    controller: ctrl,
    label: label,
    tooltip: tooltip,
    enabled: !_isAuditing,
    allowDecimal: true,
  );

  String _moveSequenceLabel(List<String> moves) => moves.isEmpty
      ? 'Initial position'
      : buildNumberedMovetext(moves, compact: true);
}
