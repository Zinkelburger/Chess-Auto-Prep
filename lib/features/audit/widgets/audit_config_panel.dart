/// Audit configuration panel — sources, thresholds, Start/Cancel, progress.
///
/// Lives in the right pane Audit tab. Triggers audits and reports results
/// back to the screen via callbacks.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../models/opening_tree.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/audit_config.dart';
import '../services/repertoire_audit_service.dart';

class AuditConfigPanel extends StatefulWidget {
  final OpeningTree? openingTree;
  final bool isWhiteRepertoire;
  final String currentFen;
  final List<String> currentMoveSequence;
  final String? repertoireFilePath;

  /// External service reference so pause/resume/cancel are accessible.
  final RepertoireAuditService? auditService;

  final void Function(bool auditing) onAuditingChanged;
  final void Function(AuditResult result) onResultReady;
  final void Function(AuditFinding finding)? onLiveFinding;
  final void Function(int checked, int total)? onProgress;
  final void Function(AuditConfig config)? onConfigChanged;

  const AuditConfigPanel({
    super.key,
    required this.openingTree,
    required this.isWhiteRepertoire,
    required this.currentFen,
    required this.currentMoveSequence,
    this.repertoireFilePath,
    this.auditService,
    required this.onAuditingChanged,
    required this.onResultReady,
    this.onLiveFinding,
    this.onProgress,
    this.onConfigChanged,
  });

  @override
  State<AuditConfigPanel> createState() => AuditConfigPanelState();
}

class AuditConfigPanelState extends State<AuditConfigPanel> {
  RepertoireAuditService? _ownedService;
  RepertoireAuditService get _service =>
      widget.auditService ?? (_ownedService ??= RepertoireAuditService());

  final TextEditingController _mistakeCtrl = TextEditingController(text: '100');
  final TextEditingController _inaccuracyCtrl =
      TextEditingController(text: '40');
  final TextEditingController _minGamesCtrl = TextEditingController(text: '50');
  final TextEditingController _minMaiaProbCtrl =
      TextEditingController(text: '0.10');
  final TextEditingController _evalDepthCtrl =
      TextEditingController(text: '14');
  final TextEditingController _maxPlyCtrl = TextEditingController(text: '30');
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2200');

  // Mothballed: Lichess Explorer disabled.
  final bool _useLichessDb = false;
  bool _auditSubtreeOnly = false;

  /// PGN file paths for repertoire-clash checking.
  final List<String> _clashPgnPaths = [];

  bool _isAuditing = false;
  AuditProgress? _progress;
  int _liveFindingCount = 0;

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
    _evalDepthCtrl.dispose();
    _maxPlyCtrl.dispose();
    _maiaEloCtrl.dispose();
    super.dispose();
  }

  // ── Audit lifecycle ──────────────────────────────────────────────────

  void cancelAudit() {
    _service.cancel();
    if (mounted) setState(() => _isAuditing = false);
    widget.onAuditingChanged(false);
    EngineLifecycle().exitGeneration();
  }

  AuditConfig _buildConfig() {
    return AuditConfig(
      mistakeThresholdCp: int.tryParse(_mistakeCtrl.text) ?? 100,
      inaccuracyThresholdCp: int.tryParse(_inaccuracyCtrl.text) ?? 40,
      minGames: int.tryParse(_minGamesCtrl.text) ?? 50,
      minMaiaProb: double.tryParse(_minMaiaProbCtrl.text) ?? 0.10,
      evalDepth: int.tryParse(_evalDepthCtrl.text) ?? 14,
      maxPly: int.tryParse(_maxPlyCtrl.text) ?? 30,
      maiaElo: int.tryParse(_maiaEloCtrl.text) ?? 2200,
      useStockfish: true,
      useLichessDb: _useLichessDb,
      useMaia: true,
      clashPgnPaths: List.unmodifiable(_clashPgnPaths),
    );
  }

  Future<void> _addClashPgns() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pgn', 'txt'],
      allowMultiple: true,
      withData: false,
      withReadStream: false,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    setState(() {
      for (final file in result.files) {
        final filePath = file.path;
        if (filePath != null && !_clashPgnPaths.contains(filePath)) {
          _clashPgnPaths.add(filePath);
        }
      }
    });
  }

  Future<void> _startAudit() async {
    if (widget.openingTree == null) return;

    final config = _buildConfig();
    widget.onConfigChanged?.call(config);

    // Capture callbacks before the dialog potentially closes and unmounts us.
    final onProgressCb = widget.onProgress;
    final onLiveFindingCb = widget.onLiveFinding;
    final onResultReadyCb = widget.onResultReady;
    final onAuditingChangedCb = widget.onAuditingChanged;
    final tree = widget.openingTree!;
    final startFen = _auditSubtreeOnly ? widget.currentFen : null;
    final isWhite = widget.isWhiteRepertoire;

    setState(() {
      _isAuditing = true;
      _progress = null;
      _liveFindingCount = 0;
    });
    onAuditingChangedCb(true);

    await EngineLifecycle().enterGeneration(1);
    await StockfishPool().ensureWorkers(1);

    try {
      final result = await _service.audit(
        tree: tree,
        isWhiteRepertoire: isWhite,
        config: config,
        startFen: startFen,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
          onProgressCb?.call(p.nodesChecked, p.totalNodes);
        },
        onFinding: (f) {
          if (mounted) setState(() => _liveFindingCount++);
          onLiveFindingCb?.call(f);
        },
      );

      if (mounted) setState(() => _isAuditing = false);
      onResultReadyCb(result);
    } catch (e) {
      if (mounted) setState(() => _isAuditing = false);
    } finally {
      onAuditingChangedCb(false);
      EngineLifecycle().exitGeneration();
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  bool _showAdvanced = false;

  @override
  Widget build(BuildContext context) {
    final scopeLabel =
        _auditSubtreeOnly && widget.currentMoveSequence.isNotEmpty
            ? 'Subtree from ${_moveSequenceLabel(widget.currentMoveSequence)}'
            : 'Full repertoire';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Scope toggle + label
          Row(
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 14, color: Colors.grey[500]),
              const SizedBox(width: 6),
              Text(scopeLabel,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const Spacer(),
              SizedBox(
                height: 28,
                child: FilterChip(
                  label: const Text('Subtree only',
                      style: TextStyle(fontSize: 11)),
                  selected: _auditSubtreeOnly,
                  onSelected: _isAuditing
                      ? null
                      : (v) => setState(() => _auditSubtreeOnly = v),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Uses Stockfish + Maia (always on)
          Row(
            children: [
              Icon(Icons.memory, size: 13, color: Colors.grey[500]),
              const SizedBox(width: 4),
              Text('Stockfish + Maia',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ],
          ),
          const SizedBox(height: 8),

          // Key thresholds
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_evalDepthCtrl, 'Eval Depth'),
              _numField(_maxPlyCtrl, 'Max Ply'),
              _numField(_maiaEloCtrl, 'Maia Elo'),
            ],
          ),
          const SizedBox(height: 8),

          // More thresholds (collapsed by default)
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.grey[500],
                ),
                const SizedBox(width: 4),
                Text('More thresholds',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ),
          if (_showAdvanced) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _numField(_mistakeCtrl, 'Mistake (cp)'),
                _numField(_inaccuracyCtrl, 'Inaccuracy (cp)'),
                _numField(_minMaiaProbCtrl, 'Min Maia Prob'),
              ],
            ),
          ],
          const SizedBox(height: 10),

          // Repertoire Clashes
          Row(
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 14, color: Colors.grey[500]),
              const SizedBox(width: 6),
              Text('Repertoire Clashes',
                  style: TextStyle(fontSize: 12, color: Colors.grey[400])),
              const Spacer(),
              SizedBox(
                height: 26,
                child: TextButton.icon(
                  onPressed: _isAuditing ? null : _addClashPgns,
                  icon: const Icon(Icons.add, size: 14),
                  label:
                      const Text('Add PGN', style: TextStyle(fontSize: 11)),
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
                      style: const TextStyle(fontSize: 11),
                    ),
                    deleteIcon: const Icon(Icons.close, size: 14),
                    onDeleted: _isAuditing
                        ? null
                        : () => setState(() => _clashPgnPaths.removeAt(i)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text('Check against book & course lines',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            ),
          const SizedBox(height: 10),

          // Start / Cancel + progress
          Row(
            children: [
              if (!_isAuditing)
                FilledButton.icon(
                  onPressed: widget.openingTree == null ? null : _startAudit,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start', style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: cancelAudit,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Cancel', style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                ),
              if (_isAuditing && _progress != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: _progress!.totalNodes > 0
                            ? _progress!.nodesChecked / _progress!.totalNodes
                            : null,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_progress!.nodesChecked}/${_progress!.totalNodes} · '
                        '$_liveFindingCount findings',
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _numField(TextEditingController ctrl, String label) {
    return SizedBox(
      width: 170,
      child: TextField(
        controller: ctrl,
        enabled: !_isAuditing,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
    );
  }

  String _moveSequenceLabel(List<String> moves) {
    if (moves.isEmpty) return 'Initial position';
    final buf = StringBuffer();
    for (int i = 0; i < moves.length; i++) {
      if (i % 2 == 0) buf.write('${(i ~/ 2) + 1}.');
      buf.write(moves[i]);
      if (i < moves.length - 1) buf.write(' ');
    }
    return buf.toString();
  }
}
