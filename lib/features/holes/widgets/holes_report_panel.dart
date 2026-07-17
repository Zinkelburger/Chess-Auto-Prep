/// Ranked hole-hunt report for the Findings tab.
///
/// Unlike the audit findings panel this is deliberately lean: a flat list
/// sorted by exploit score (reach probability × gain), capped to a handful
/// of killer holes, with per-type filter chips and simple dismissal.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/widgets/finding_style.dart';
import '../../audit/widgets/finding_tile.dart';
import '../services/hole_hunt_service.dart';
import '../services/hole_scoring.dart';

class HolesReportPanel extends StatefulWidget {
  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isHunting;
  final HoleHuntProgress? progress;

  /// Show the "trap search skipped" note (Maia unavailable).
  final bool trapPassSkipped;

  final void Function(AuditFinding finding)? onFindingSelected;
  final void Function(AuditResult result)? onResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHunt;

  const HolesReportPanel({
    super.key,
    required this.result,
    required this.liveFindings,
    required this.isHunting,
    this.progress,
    this.trapPassSkipped = false,
    this.onFindingSelected,
    this.onResultChanged,
    this.onStartHunt,
  });

  @override
  State<HolesReportPanel> createState() => _HolesReportPanelState();
}

class _HolesReportPanelState extends State<HolesReportPanel> {
  static const int _defaultCap = 10;

  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _capCtrl = TextEditingController(
    text: '$_defaultCap',
  );

  /// Empty = all types.
  final Set<AuditFindingType> _activeFilters = {};
  int _maxVisible = _defaultCap;
  int _selectedIndex = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  List<AuditFinding> get _allFindings => [
    ...(widget.result?.findings ?? const <AuditFinding>[]),
    ...widget.liveFindings,
  ];

  List<AuditFinding> _visibleFindings() {
    final ranked = rankByExploitScore(
      _allFindings.where((f) {
        if (f.dismissed) return false;
        if (_activeFilters.isNotEmpty && !_activeFilters.contains(f.type)) {
          return false;
        }
        return true;
      }).toList(),
    );
    return ranked.length > _maxVisible
        ? ranked.sublist(0, _maxVisible)
        : ranked;
  }

  void _toggleDismiss(AuditFinding finding) {
    setState(() => finding.dismissed = !finding.dismissed);
    final result = widget.result;
    if (result != null) widget.onResultChanged?.call(result);
  }

  void _restoreAll() {
    setState(() {
      for (final f in _allFindings) {
        f.dismissed = false;
      }
    });
    final result = widget.result;
    if (result != null) widget.onResultChanged?.call(result);
  }

  int _countOf(AuditFindingType type) =>
      _allFindings.where((f) => f.type == type && !f.dismissed).length;

  @override
  Widget build(BuildContext context) {
    final findings = _visibleFindings();
    final dismissedCount = _allFindings.where((f) => f.dismissed).length;

    if (_allFindings.isEmpty && !widget.isHunting) {
      return _buildEmptyState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeaderRow(),
        if (widget.trapPassSkipped)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Text(
              'Trap search skipped — Maia unavailable',
              style: TextStyle(fontSize: 11, color: AppColors.warning),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: findings.isEmpty
              ? Center(
                  child: Text(
                    widget.isHunting
                        ? 'Hunting for holes...'
                        : 'No holes match the current filters',
                    style: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: findings.length,
                  itemExtent: 56,
                  itemBuilder: (context, index) {
                    final finding = findings[index];
                    return FindingTile(
                      finding: finding,
                      isSelected: index == _selectedIndex,
                      color: findingColor(finding),
                      icon: findingIcon(finding),
                      onSelect: () {
                        setState(() => _selectedIndex = index);
                        widget.onFindingSelected?.call(finding);
                      },
                      onToggleDismiss: () => _toggleDismiss(finding),
                      onContextMenu: (_) {},
                    );
                  },
                ),
        ),
        if (dismissedCount > 0) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(
                  '$dismissedCount dismissed',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _restoreAll,
                  child: const Text(
                    'Restore all',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHeaderRow() {
    final progress = widget.progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(
        children: [
          _filterChip('Uncovered', AuditFindingType.uncoveredStrongMove),
          const SizedBox(width: 6),
          _filterChip('Refutations', AuditFindingType.refutation),
          const SizedBox(width: 6),
          _filterChip('Traps', AuditFindingType.practicalTrap),
          const Spacer(),
          if (widget.isHunting && progress != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                progress.message,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            )
          else if (widget.onStartHunt != null)
            SizedBox(
              height: 26,
              child: TextButton.icon(
                onPressed: widget.onStartHunt,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Re-run', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          const SizedBox(width: 6),
          const Text(
            'Show',
            style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 40,
            height: 26,
            child: TextField(
              controller: _capCtrl,
              style: const TextStyle(fontSize: 11),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 4),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onSubmitted: (v) =>
                  setState(() => _maxVisible = int.tryParse(v) ?? _defaultCap),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, AuditFindingType type) {
    final selected = _activeFilters.contains(type);
    final count = _countOf(type);
    return SizedBox(
      height: 26,
      child: FilterChip(
        label: Text('$label ($count)', style: const TextStyle(fontSize: 11)),
        selected: selected,
        onSelected: (v) => setState(() {
          if (v) {
            _activeFilters.add(type);
          } else {
            _activeFilters.remove(type);
          }
        }),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.gps_fixed, size: 40, color: AppColors.onSurfaceDim),
          const SizedBox(height: 12),
          const Text(
            'No hole report yet',
            style: TextStyle(
              color: AppColors.onSurfaceSoft,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Find Holes attacks these lines from the opposite side — '
            'uncovered replies, verified refutations, and Maia '
            'expectimax traps at end positions — then ranks a short '
            'list of killer holes. Different from Analyze with Engine, '
            'which only colors positions by raw Stockfish eval.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (widget.onStartHunt != null)
            OutlinedButton.icon(
              onPressed: widget.onStartHunt,
              icon: const Icon(Icons.gps_fixed, size: 16),
              label: const Text('Find Holes'),
            ),
        ],
      ),
    );
  }
}
