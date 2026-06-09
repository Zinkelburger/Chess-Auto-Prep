/// Audit findings display — summary card, findings list, sort/filter/dismiss.
///
/// Lives in the bottom pane Findings tab. Receives results from the screen
/// state; does not own the audit service.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';

enum FindingsSortMode { severity, reachProb, ply }

class AuditFindingsPanel extends StatefulWidget {
  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isAuditing;
  final void Function(List<String> movePath)? onNavigateToPosition;
  final void Function(AuditResult updatedResult)? onResultChanged;

  const AuditFindingsPanel({
    super.key,
    this.result,
    this.liveFindings = const [],
    this.isAuditing = false,
    this.onNavigateToPosition,
    this.onResultChanged,
  });

  @override
  State<AuditFindingsPanel> createState() => AuditFindingsPanelState();
}

class AuditFindingsPanelState extends State<AuditFindingsPanel> {
  AuditFindingType? _filterType;
  FindingsSortMode _sortMode = FindingsSortMode.severity;
  bool _hideDismissed = true;

  void setFilterType(AuditFindingType? type) {
    setState(() => _filterType = _filterType == type ? null : type);
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasData = widget.result != null || widget.liveFindings.isNotEmpty;

    if (!hasData && !widget.isAuditing) {
      return const Center(
        child: Text(
          'No audit results yet.\nStart an audit from the Audit tab.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    return Column(
      children: [
        if (widget.result != null) ...[
          _buildSummaryCard(widget.result!),
          const Divider(height: 1),
        ],
        _buildFindingsHeader(),
        const Divider(height: 1),
        Expanded(child: _buildFindingsList()),
      ],
    );
  }

  // ── Summary card ─────────────────────────────────────────────────────

  Widget _buildSummaryCard(AuditResult result) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
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
          const SizedBox(width: 16),
          _metricChip(
            '${result.coveragePercent.toStringAsFixed(0)}%',
            'Coverage',
            result.coveragePercent >= 90
                ? AppColors.evalPositive
                : result.coveragePercent >= 70
                    ? Colors.orange
                    : AppColors.evalNegative,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
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
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String value, String label, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
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
      onPressed: () => setFilterType(type),
    );
  }

  // ── Findings header ──────────────────────────────────────────────────

  Widget _buildFindingsHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Text('Findings', style: Theme.of(context).textTheme.labelLarge),
          const Spacer(),
          Tooltip(
            message: _hideDismissed ? 'Show dismissed' : 'Hide dismissed',
            child: IconButton(
              icon: Icon(
                _hideDismissed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16,
                color: Colors.grey,
              ),
              onPressed: () =>
                  setState(() => _hideDismissed = !_hideDismissed),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
          PopupMenuButton<FindingsSortMode>(
            tooltip: 'Sort findings',
            icon: const Icon(Icons.sort, size: 16, color: Colors.grey),
            padding: EdgeInsets.zero,
            onSelected: (v) => setState(() => _sortMode = v),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: FindingsSortMode.severity,
                checked: _sortMode == FindingsSortMode.severity,
                child: const Text('Severity'),
              ),
              CheckedPopupMenuItem(
                value: FindingsSortMode.reachProb,
                checked: _sortMode == FindingsSortMode.reachProb,
                child: const Text('Reach probability'),
              ),
              CheckedPopupMenuItem(
                value: FindingsSortMode.ply,
                checked: _sortMode == FindingsSortMode.ply,
                child: const Text('Ply depth'),
              ),
            ],
          ),
          PopupMenuButton<AuditFindingType?>(
            tooltip: 'Filter by type',
            icon: Icon(
              Icons.filter_list,
              size: 16,
              color: _filterType != null ? Colors.blue : Colors.grey,
            ),
            padding: EdgeInsets.zero,
            onSelected: (v) => setState(() => _filterType = v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('All')),
              const PopupMenuItem(
                  value: AuditFindingType.mistake, child: Text('Mistakes')),
              const PopupMenuItem(
                  value: AuditFindingType.inaccuracy,
                  child: Text('Inaccuracies')),
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
      ),
    );
  }

  // ── Findings list ────────────────────────────────────────────────────

  Widget _buildFindingsList() {
    final findings = widget.result?.findings ?? widget.liveFindings;
    var filtered = findings.where((f) {
      if (_hideDismissed && f.dismissed) return false;
      if (_filterType != null && f.type != _filterType) return false;
      return true;
    }).toList();

    filtered = _sortFindings(filtered);

    if (filtered.isEmpty) {
      return const Center(
        child: Text('No findings match filters',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildFindingTile(filtered[index]),
    );
  }

  List<AuditFinding> _sortFindings(List<AuditFinding> list) {
    switch (_sortMode) {
      case FindingsSortMode.severity:
        list.sort((a, b) {
          final cmp = a.severity.index.compareTo(b.severity.index);
          if (cmp != 0) return cmp;
          return (b.cumulativeProbability ?? 0)
              .compareTo(a.cumulativeProbability ?? 0);
        });
      case FindingsSortMode.reachProb:
        list.sort((a, b) => (b.cumulativeProbability ?? 0)
            .compareTo(a.cumulativeProbability ?? 0));
      case FindingsSortMode.ply:
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Icon(icon, color: color, size: 16),
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
            size: 14,
            color: Colors.grey,
          ),
          tooltip: finding.dismissed ? 'Restore' : 'Dismiss',
          onPressed: () {
            setState(() => finding.dismissed = !finding.dismissed);
            if (widget.result != null) {
              widget.onResultChanged?.call(widget.result!);
            }
          },
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        onTap: () {
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
}
