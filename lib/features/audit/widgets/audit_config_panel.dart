/// Audit configuration panel — sources, thresholds, Start/Cancel, progress.
///
/// Lives in the right pane Audit tab. Triggers audits and reports results
/// back to the screen via callbacks.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/opening_tree.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/storage/storage_factory.dart';
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

  final void Function(bool auditing) onAuditingChanged;
  final void Function(AuditResult result) onResultReady;
  final void Function(AuditFinding finding)? onLiveFinding;

  const AuditConfigPanel({
    super.key,
    required this.openingTree,
    required this.isWhiteRepertoire,
    required this.currentFen,
    required this.currentMoveSequence,
    this.repertoireFilePath,
    required this.onAuditingChanged,
    required this.onResultReady,
    this.onLiveFinding,
  });

  @override
  State<AuditConfigPanel> createState() => AuditConfigPanelState();
}

class AuditConfigPanelState extends State<AuditConfigPanel> {
  final RepertoireAuditService _service = RepertoireAuditService();

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
  bool _useLichessDb = true;
  bool _useMaia = true;
  bool _auditSubtreeOnly = false;

  bool _isAuditing = false;
  AuditProgress? _progress;
  int _liveFindingCount = 0;

  bool get isAuditing => _isAuditing;

  @override
  void initState() {
    super.initState();
    _tryLoadSavedResult();
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

  // ── Persistence ──────────────────────────────────────────────────────

  String? get _auditFilePath {
    final fp = widget.repertoireFilePath;
    if (fp == null || fp.isEmpty) return null;
    final base = fp.endsWith('.pgn') ? fp.substring(0, fp.length - 4) : fp;
    return '${base}_audit.json';
  }

  Future<void> _tryLoadSavedResult() async {
    final path = _auditFilePath;
    if (path == null) return;
    try {
      final json = await StorageFactory.instance.readFile(path);
      if (json != null && json.isNotEmpty && mounted) {
        widget.onResultReady(AuditResult.fromJsonString(json));
      }
    } catch (_) {}
  }

  Future<void> _saveResult(AuditResult result) async {
    final path = _auditFilePath;
    if (path == null) return;
    try {
      await StorageFactory.instance.writeFile(path, result.toJsonString());
    } catch (_) {}
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
    setState(() {
      _isAuditing = true;
      _progress = null;
      _liveFindingCount = 0;
    });
    widget.onAuditingChanged(true);

    if (config.useStockfish) {
      await EngineLifecycle().enterGeneration(1);
      await StockfishPool().ensureWorkers(1);
    }

    try {
      final result = await _service.audit(
        tree: widget.openingTree!,
        isWhiteRepertoire: widget.isWhiteRepertoire,
        config: config,
        startFen: _auditSubtreeOnly ? widget.currentFen : null,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onFinding: (f) {
          if (mounted) {
            setState(() => _liveFindingCount++);
            widget.onLiveFinding?.call(f);
          }
        },
      );

      if (mounted) {
        setState(() => _isAuditing = false);
        widget.onResultReady(result);
        unawaited(_saveResult(result));
      }
    } catch (e) {
      if (mounted) setState(() => _isAuditing = false);
    } finally {
      widget.onAuditingChanged(false);
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
              FilterChip(
                label: const Text('Lichess DB'),
                selected: _useLichessDb,
                onSelected:
                    _isAuditing ? null : (v) => setState(() => _useLichessDb = v),
              ),
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
