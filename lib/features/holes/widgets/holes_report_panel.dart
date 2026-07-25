/// Ranked hole-hunt report for the Findings tab.
///
/// Unlike the audit findings panel this is deliberately lean: a flat list
/// sorted by exploit score (reach probability × gain), capped to a handful
/// of killer holes, with per-type filter chips and simple dismissal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// [AuditFinding.dismissKey] of the selected finding — the list re-ranks
  /// as findings stream in, so a raw index would drift.
  String? _selectedKey;

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

  bool _matchesFilters(AuditFinding f) {
    if (f.dismissed) return false;
    if (_activeFilters.isNotEmpty && !_activeFilters.contains(f.type)) {
      return false;
    }
    return true;
  }

  /// Findings that match the filters, before the visible cap.
  int get _totalMatching => _allFindings.where(_matchesFilters).length;

  List<AuditFinding> _visibleFindings() {
    final ranked = rankByExploitScore(
      _allFindings.where(_matchesFilters).toList(),
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

  void _dismissAllOfType(AuditFindingType type) {
    setState(() {
      for (final f in _allFindings) {
        if (f.type == type) f.dismissed = true;
      }
    });
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

  void _applyCapFromField() {
    final parsed = int.tryParse(_capCtrl.text.trim());
    if (parsed == null || parsed < 1) {
      _capCtrl.text = '$_maxVisible';
      return;
    }
    final clamped = parsed.clamp(1, 999);
    if (clamped != _maxVisible) {
      setState(() {
        _maxVisible = clamped;
        _capCtrl.text = '$clamped';
      });
    } else {
      _capCtrl.text = '$clamped';
    }
  }

  /// Gain (cp) recovered from the stored exploit score — the same value
  /// `hole_scoring.exploitScoreOf` multiplied by the reach probability.
  int? _gainCpOf(AuditFinding f) {
    final score = f.exploitScore;
    final p = f.cumulativeProbability;
    if (score != null && p != null && p > 0) return (score / p).round();
    return switch (f.type) {
      AuditFindingType.refutation => f.evalLossCp,
      AuditFindingType.practicalTrap => f.practicalGapCp,
      _ => null,
    };
  }

  String? _gainLabelOf(AuditFinding f) {
    final cp = _gainCpOf(f);
    if (cp == null) return null;
    return '+${(cp / 100).toStringAsFixed(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final findings = _visibleFindings();
    final dismissedCount = _allFindings.where((f) => f.dismissed).length;

    // Drop the selection once its finding leaves the visible list (already
    // rebuilding, so a plain field write is enough).
    if (_selectedKey != null &&
        !findings.any((f) => f.dismissKey == _selectedKey)) {
      _selectedKey = null;
    }

    if (_allFindings.isEmpty && !widget.isHunting) {
      return _buildEmptyState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildChipsRow(),
        _buildStatusRow(
          visibleCount: findings.length,
          totalMatching: _totalMatching,
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
                      isSelected: finding.dismissKey == _selectedKey,
                      color: findingColor(finding),
                      icon: findingIcon(finding),
                      gainLabel: _gainLabelOf(finding),
                      onSelect: () {
                        setState(() => _selectedKey = finding.dismissKey);
                        widget.onFindingSelected?.call(finding);
                      },
                      onToggleDismiss: () => _toggleDismiss(finding),
                      onContextMenu: (pos) => _showDismissMenu(pos, finding),
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

  Widget _buildChipsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _filterChip('Uncovered', AuditFindingType.uncoveredStrongMove),
          _filterChip('Refutations', AuditFindingType.refutation),
          _filterChip('Traps', AuditFindingType.practicalTrap),
        ],
      ),
    );
  }

  Widget _buildStatusRow({
    required int visibleCount,
    required int totalMatching,
  }) {
    final progress = widget.progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            if (totalMatching > visibleCount) ...[
              const Text(
                'Top',
                style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
              ),
              const SizedBox(width: 3),
              SizedBox(width: 34, height: 20, child: _capField(context)),
              const SizedBox(width: 3),
              Text(
                'of $totalMatching',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ] else
              Text(
                '$visibleCount findings',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Fixed-width slot so the Re-run button never shifts when
                  // the trap-pass note appears.
                  SizedBox(
                    width: 22,
                    child: widget.trapPassSkipped
                        ? const Tooltip(
                            message: 'Trap search skipped — Maia unavailable',
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: AppColors.warning,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 4),
                  if (widget.isHunting && progress != null)
                    Flexible(
                      child: Text(
                        progress.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                        label: const Text(
                          'Re-run',
                          style: TextStyle(fontSize: 11),
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
            ),
          ],
        ),
      ),
    );
  }

  /// Visible-cap editor, same recipe as `AuditStatusRow`: digits only,
  /// applied on submit and on tap-outside, clamped 1..999.
  Widget _capField(BuildContext context) {
    return TextField(
      controller: _capCtrl,
      style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceSoft),
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: AppColors.outline, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: AppColors.outline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(
            color: AppColors.onSurfaceMuted,
            width: 1,
          ),
        ),
      ),
      onSubmitted: (_) => _applyCapFromField(),
      onTapOutside: (_) {
        _applyCapFromField();
        FocusScope.of(context).unfocus();
      },
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
        // Disabled at zero; stays live while selected so it can be
        // toggled back off.
        onSelected: (count > 0 || selected)
            ? (v) => setState(() {
                if (v) {
                  _activeFilters.add(type);
                } else {
                  _activeFilters.remove(type);
                }
              })
            : null,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    );
  }

  // ── Dismiss context menu ──────────────────────────────────────────────

  void _showDismissMenu(Offset position, AuditFinding finding) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        PopupMenuItem(
          value: 'dismiss',
          child: Text(
            finding.dismissed ? 'Restore' : 'Dismiss',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        PopupMenuItem(
          value: 'type',
          child: Text(
            'Dismiss all ${_typeLabel(finding.type)}',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'dismiss':
          _toggleDismiss(finding);
        case 'type':
          _dismissAllOfType(finding.type);
      }
    });
  }

  String _typeLabel(AuditFindingType type) {
    return switch (type) {
      AuditFindingType.uncoveredStrongMove => 'uncovered strong moves',
      AuditFindingType.refutation => 'refutations',
      AuditFindingType.practicalTrap => 'practical traps',
      _ => type.name,
    };
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
