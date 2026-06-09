/// Audit configuration panel — sources, thresholds, Start/Cancel, progress.
///
/// Lives in the right pane Audit tab. Triggers audits and reports results
/// back to the screen via callbacks.
library;

import 'package:flutter/material.dart';

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

  final TextEditingController _mistakeCtrl =
      TextEditingController(text: '100');
  final TextEditingController _inaccuracyCtrl =
      TextEditingController(text: '40');
  final TextEditingController _minGamesCtrl =
      TextEditingController(text: '50');
  final TextEditingController _minMaiaProbCtrl =
      TextEditingController(text: '0.10');
  final TextEditingController _evalDepthCtrl =
      TextEditingController(text: '14');
  final TextEditingController _maxPlyCtrl =
      TextEditingController(text: '30');
  final TextEditingController _maiaEloCtrl =
      TextEditingController(text: '2200');

  bool _useStockfish = true;
  // Mothballed: Lichess Explorer disabled.
  bool _useLichessDb = false;
  bool _useMaia = true;
  bool _auditSubtreeOnly = false;

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
      useStockfish: _useStockfish,
      useLichessDb: _useLichessDb,
      useMaia: _useMaia,
    );
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

    if (config.useStockfish) {
      await EngineLifecycle().enterGeneration(1);
      await StockfishPool().ensureWorkers(1);
    }

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
      if (config.useStockfish) {
        EngineLifecycle().exitGeneration();
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Repertoire Audit', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            _auditSubtreeOnly && widget.currentMoveSequence.isNotEmpty
                ? 'From: ${_moveSequenceLabel(widget.currentMoveSequence)}'
                : 'Full repertoire from root',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Audit from current position only',
                style: TextStyle(fontSize: 13)),
            value: _auditSubtreeOnly,
            onChanged:
                _isAuditing ? null : (v) => setState(() => _auditSubtreeOnly = v),
          ),
          const SizedBox(height: 8),

          Text('Sources', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('Stockfish'),
                selected: _useStockfish,
                onSelected:
                    _isAuditing ? null : (v) => setState(() => _useStockfish = v),
              ),
              // Mothballed: Lichess Explorer chip hidden.
              FilterChip(
                label: const Text('Maia'),
                selected: _useMaia,
                onSelected:
                    _isAuditing ? null : (v) => setState(() => _useMaia = v),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Text('Thresholds', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _numField(_mistakeCtrl, 'Mistake (cp)'),
              _numField(_inaccuracyCtrl, 'Inaccuracy (cp)'),
              _numField(_minGamesCtrl, 'Min games'),
              _numField(_minMaiaProbCtrl, 'Min Maia prob'),
              _numField(_evalDepthCtrl, 'Eval depth'),
              _numField(_maxPlyCtrl, 'Max ply'),
              _numField(_maiaEloCtrl, 'Maia ELO'),
            ],
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              if (!_isAuditing)
                FilledButton.icon(
                  onPressed: widget.openingTree == null ? null : _startAudit,
                  icon: const Icon(Icons.policy_outlined, size: 18),
                  label: const Text('Start Audit'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: cancelAudit,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Cancel'),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (_isAuditing && _progress != null) ...[
            LinearProgressIndicator(
              value: _progress!.totalNodes > 0
                  ? _progress!.nodesChecked / _progress!.totalNodes
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              '${_progress!.nodesChecked} / ${_progress!.totalNodes} nodes  '
              '· $_liveFindingCount findings',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  Widget _numField(TextEditingController ctrl, String label) {
    return SizedBox(
      width: 120,
      child: TextField(
        controller: ctrl,
        enabled: !_isAuditing,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 13),
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
