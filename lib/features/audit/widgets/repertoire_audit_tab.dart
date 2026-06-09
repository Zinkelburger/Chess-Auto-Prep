/// Full audit panel — config, progress, summary, findings list.
///
/// Mirrors the structure of [RepertoireGenerationTab] as a mode overlay
/// inside [RepertoireScreen].
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/opening_tree.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/audit_config.dart';
import '../services/repertoire_audit_service.dart';

/// Sort modes for the findings list.
enum _SortMode { severity, reachProb, ply }

class RepertoireAuditTab extends StatefulWidget {
  final OpeningTree? openingTree;
  final bool isWhiteRepertoire;
  final String currentFen;
  final List<String> currentMoveSequence;
  final void Function(bool auditing) onAuditingChanged;
  final void Function(List<String> movePath)? onNavigateToPosition;

  /// Absolute path to the repertoire PGN file (for persisting audit results).
  final String? repertoireFilePath;

  const RepertoireAuditTab({
    super.key,
    required this.openingTree,
    required this.isWhiteRepertoire,
    required this.currentFen,
    required this.currentMoveSequence,
    required this.onAuditingChanged,
    this.onNavigateToPosition,
    this.repertoireFilePath,
  });

  @override
  State<RepertoireAuditTab> createState() => RepertoireAuditTabState();
}

class RepertoireAuditTabState extends State<RepertoireAuditTab> {
  final RepertoireAuditService _service = RepertoireAuditService();

  // Config controllers
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

  // State
  bool _isAuditing = false;
  bool _loadedFromDisk = false;
  AuditProgress? _progress;
  AuditResult? _result;
  AuditResult? get result => _result;
  final List<AuditFinding> _liveFindings = [];
  AuditFindingType? _filterType;
  _SortMode _sortMode = _SortMode.severity;
  bool _hideDismissed = true;

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

  // ── Persistence ────────────────────────────────────────────────────────

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
        setState(() {
          _result = AuditResult.fromJsonString(json);
          _loadedFromDisk = true;
        });
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

  // ── Audit lifecycle ────────────────────────────────────────────────────

  void cancelAudit() {
    _service.cancel();
    if (mounted) {
      setState(() => _isAuditing = false);
    }
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
      _result = null;
      _loadedFromDisk = false;
      _liveFindings.clear();
      _progress = null;
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
          if (mounted) setState(() => _liveFindings.add(f));
        },
      );

      if (mounted) {
        setState(() {
          _result = result;
          _isAuditing = false;
        });
        unawaited(_saveResult(result));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAuditing = false);
      }
    } finally {
      widget.onAuditingChanged(false);
      if (config.useStockfish) {
        EngineLifecycle().exitGeneration();
      }
    }
  }

  void _dismissFinding(AuditFinding finding) {
    setState(() => finding.dismissed = true);
    if (_result != null) unawaited(_saveResult(_result!));
  }

  void _restoreFinding(AuditFinding finding) {
    setState(() => finding.dismissed = false);
    if (_result != null) unawaited(_saveResult(_result!));
  }

  // ── Build ──────────────────────────────────────────────────────────────

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

          // Scope toggle
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

          // Source toggles
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

          // Threshold config
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

          // Action buttons
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

          // Progress
          if (_isAuditing && _progress != null) ...[
            LinearProgressIndicator(
              value: _progress!.totalNodes > 0
                  ? _progress!.nodesChecked / _progress!.totalNodes
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              '${_progress!.nodesChecked} / ${_progress!.totalNodes} nodes  '
              '· ${_liveFindings.length} findings',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
          ],

          // Summary (after completion or loaded)
          if (_result != null) ...[
            _buildSummaryCard(_result!),
            const SizedBox(height: 12),
          ],

          // Findings list
          if (_result != null || _liveFindings.isNotEmpty) ...[
            _buildFindingsHeader(),
            const SizedBox(height: 4),
            _buildFindingsList(),
          ],
        ],
      ),
    );
  }

  // ── Summary card ────────────────────────────────────────────────────────

  Widget _buildSummaryCard(AuditResult result) {
    final ts = result.timestamp;
    final when = _loadedFromDisk && ts != null
        ? _relativeTime(ts)
        : null;

    return Card(
      color: AppColors.surfaceElevated,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Audit Complete',
                    style: Theme.of(context).textTheme.titleSmall),
                if (when != null) ...[
                  const SizedBox(width: 8),
                  Text('($when)',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _metricChip(
                  '${result.soundnessPercent.toStringAsFixed(0)}%',
                  'Sound',
                  result.soundnessPercent >= 90
                      ? AppColors.evalPositive
                      : result.soundnessPercent >= 70
                          ? Colors.orange
                          : AppColors.evalNegative,
                ),
                const SizedBox(width: 12),
                _metricChip(
                  '${result.coveragePercent.toStringAsFixed(0)}%',
                  'Coverage',
                  result.coveragePercent >= 90
                      ? AppColors.evalPositive
                      : result.coveragePercent >= 70
                          ? Colors.orange
                          : AppColors.evalNegative,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${result.nodesChecked} nodes in '
              '${result.elapsed.inSeconds}s  ·  '
              '${result.activeFindingCount} active / '
              '${result.findings.length} total findings',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (result.totalEvalLookups > 0)
              Text(
                'Eval cache: ${result.evalCacheHits}/${result.totalEvalLookups} '
                '(${result.evalCacheHitPercent.toStringAsFixed(0)}% hit)',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (result.mistakeCount > 0)
                  _countBadge(result.mistakeCount, 'mistakes',
                      AppColors.evalNegative, AuditFindingType.mistake),
                if (result.inaccuracyCount > 0)
                  _countBadge(result.inaccuracyCount, 'inaccuracies',
                      Colors.orange, AuditFindingType.inaccuracy),
                if (result.missingResponseCount > 0)
                  _countBadge(result.missingResponseCount, 'missing',
                      Colors.blue, AuditFindingType.missingResponse),
                if (result.weakPositionCount > 0)
                  _countBadge(result.weakPositionCount, 'weak',
                      Colors.deepOrange, AuditFindingType.weakPosition),
                if (result.deadEndCount > 0)
                  _countBadge(result.deadEndCount, 'dead ends',
                      AppColors.onSurfaceMuted, AuditFindingType.deadEnd),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricChip(String value, String label, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _countBadge(
      int count, String label, Color color, AuditFindingType type) {
    final isActive = _filterType == type;
    return ActionChip(
      visualDensity: VisualDensity.compact,
      label: Text('$count $label',
          style: TextStyle(
              fontSize: 11,
              color: isActive ? Colors.white : color,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
      backgroundColor: isActive ? color.withValues(alpha: 0.8) : null,
      side: BorderSide(color: color.withValues(alpha: isActive ? 1.0 : 0.4)),
      padding: EdgeInsets.zero,
      onPressed: () => setState(() {
        _filterType = _filterType == type ? null : type;
      }),
    );
  }

  // ── Findings list ───────────────────────────────────────────────────────

  Widget _buildFindingsHeader() {
    return Row(
      children: [
        Text('Findings', style: Theme.of(context).textTheme.labelLarge),
        const Spacer(),

        // Hide dismissed toggle
        Tooltip(
          message: _hideDismissed ? 'Show dismissed' : 'Hide dismissed',
          child: IconButton(
            icon: Icon(
              _hideDismissed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 18,
              color: Colors.grey,
            ),
            onPressed: () => setState(() => _hideDismissed = !_hideDismissed),
            visualDensity: VisualDensity.compact,
          ),
        ),

        // Sort mode
        PopupMenuButton<_SortMode>(
          tooltip: 'Sort findings',
          icon: const Icon(Icons.sort, size: 18, color: Colors.grey),
          onSelected: (v) => setState(() => _sortMode = v),
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: _SortMode.severity,
              checked: _sortMode == _SortMode.severity,
              child: const Text('Severity'),
            ),
            CheckedPopupMenuItem(
              value: _SortMode.reachProb,
              checked: _sortMode == _SortMode.reachProb,
              child: const Text('Reach probability'),
            ),
            CheckedPopupMenuItem(
              value: _SortMode.ply,
              checked: _sortMode == _SortMode.ply,
              child: const Text('Ply depth'),
            ),
          ],
        ),

        // Filter by type
        PopupMenuButton<AuditFindingType?>(
          tooltip: 'Filter by type',
          icon: Icon(
            Icons.filter_list,
            size: 18,
            color: _filterType != null ? Colors.blue : Colors.grey,
          ),
          onSelected: (v) => setState(() => _filterType = v),
          itemBuilder: (_) => [
            const PopupMenuItem(value: null, child: Text('All')),
            const PopupMenuItem(
                value: AuditFindingType.mistake, child: Text('Mistakes')),
            const PopupMenuItem(
                value: AuditFindingType.inaccuracy, child: Text('Inaccuracies')),
            const PopupMenuItem(
                value: AuditFindingType.missingResponse,
                child: Text('Missing responses')),
            const PopupMenuItem(
                value: AuditFindingType.weakPosition,
                child: Text('Weak positions')),
            const PopupMenuItem(
                value: AuditFindingType.deadEnd, child: Text('Dead ends')),
          ],
        ),
      ],
    );
  }

  Widget _buildFindingsList() {
    final findings = _result?.findings ?? _liveFindings;
    var filtered = findings.where((f) {
      if (_hideDismissed && f.dismissed) return false;
      if (_filterType != null && f.type != _filterType) return false;
      return true;
    }).toList();

    filtered = _sortFindings(filtered);

    if (filtered.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('No findings', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildFindingTile(filtered[index]),
    );
  }

  List<AuditFinding> _sortFindings(List<AuditFinding> list) {
    switch (_sortMode) {
      case _SortMode.severity:
        list.sort((a, b) {
          final cmp = a.severity.index.compareTo(b.severity.index);
          if (cmp != 0) return cmp;
          return (b.cumulativeProbability ?? 0)
              .compareTo(a.cumulativeProbability ?? 0);
        });
      case _SortMode.reachProb:
        list.sort((a, b) => (b.cumulativeProbability ?? 0)
            .compareTo(a.cumulativeProbability ?? 0));
      case _SortMode.ply:
        list.sort((a, b) => a.movePath.length.compareTo(b.movePath.length));
    }
    return list;
  }

  Widget _buildFindingTile(AuditFinding finding) {
    final color = _findingColor(finding);
    final icon = _findingIcon(finding);
    final reach = finding.reachProbLabel;

    return Opacity(
      opacity: finding.dismissed ? 0.45 : 1.0,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(icon, color: color, size: 18),
        title: Text(finding.summary, style: const TextStyle(fontSize: 12)),
        subtitle: Text(
          reach != null
              ? '${finding.movePathString}  ·  $reach reach'
              : finding.movePathString,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: IconButton(
          icon: Icon(
            finding.dismissed ? Icons.undo : Icons.close,
            size: 16,
            color: Colors.grey,
          ),
          tooltip: finding.dismissed ? 'Restore' : 'Dismiss',
          onPressed: () => finding.dismissed
              ? _restoreFinding(finding)
              : _dismissFinding(finding),
          visualDensity: VisualDensity.compact,
        ),
        onTap: () {
          // For missing responses, navigate AFTER the missing move.
          if (finding.type == AuditFindingType.missingResponse &&
              finding.missingMove != null) {
            widget.onNavigateToPosition
                ?.call([...finding.movePath, finding.missingMove!]);
          } else {
            widget.onNavigateToPosition?.call(finding.movePath);
          }
        },
      ),
    );
  }

  Color _findingColor(AuditFinding finding) {
    switch (finding.severity) {
      case AuditSeverity.critical:
        return AppColors.evalNegative;
      case AuditSeverity.warning:
        return Colors.orange;
      case AuditSeverity.info:
        return AppColors.onSurfaceMuted;
    }
  }

  IconData _findingIcon(AuditFinding finding) {
    switch (finding.type) {
      case AuditFindingType.mistake:
        return Icons.error_outline;
      case AuditFindingType.inaccuracy:
        return Icons.warning_amber_outlined;
      case AuditFindingType.missingResponse:
        return Icons.visibility_off_outlined;
      case AuditFindingType.weakPosition:
        return Icons.trending_down;
      case AuditFindingType.deadEnd:
        return Icons.block_outlined;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

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

  static String _relativeTime(DateTime ts) {
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
