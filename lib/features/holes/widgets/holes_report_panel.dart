/// The ranked hole-hunt report: a flat list of findings sorted by exploit
/// score, capped to a handful of the best, with per-type filter chips,
/// simple dismissal and prev/next stepping.
///
/// Deliberately leaner than the full audit findings panel — a short killer
/// list to work down, each row driving the board — not a breadth checklist.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/anchor_menu.dart';
import '../../../widgets/common/list_nav.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/services/exploit_ranking.dart';
import '../../audit/widgets/finding_style.dart';
import '../../audit/widgets/finding_tile.dart';
import '../../audit/widgets/hunt_controls.dart';
import '../services/hole_hunt_service.dart';

/// Gain (cp) recovered from the stored exploit score — the same value
/// `exploitScoreOf` multiplied by the reach probability.
///
/// Falls back to the raw per-type number for a finding written before
/// exploit scores were stored.
int? holeGainCp(AuditFinding f) {
  final score = f.exploitScore;
  final p = f.cumulativeProbability;
  if (score != null && p != null && p > 0) return (score / p).round();
  return switch (f.type) {
    AuditFindingType.refutation => f.evalLossCp,
    AuditFindingType.trickyMove => f.netGainCp,
    _ => null,
  };
}

/// One filter chip: a name, the finding type it matches, and what dismissing
/// everything of that type should be called in the context menu (the chip
/// label alone reads wrong there: "Dismiss all Refutations (3)").
class _Filter {
  const _Filter(this.label, this.type, this.dismissAllLabel);

  final String label;
  final AuditFindingType type;
  final String dismissAllLabel;

  bool matches(AuditFinding f) => f.type == type;
}

const _filters = [
  _Filter(
    'Uncovered',
    AuditFindingType.uncoveredStrongMove,
    'uncovered strong moves',
  ),
  _Filter('Refutations', AuditFindingType.refutation, 'refutations'),
  _Filter('Tricks', AuditFindingType.trickyMove, 'tricks'),
];

class HolesReportPanel extends StatefulWidget {
  const HolesReportPanel({
    super.key,
    required this.result,
    required this.liveFindings,
    required this.isHunting,
    this.progress,
    this.probesSkipped = false,
    this.onFindingSelected,
    this.onResultChanged,
    this.onStartHunt,
    this.navController,
  });

  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isHunting;

  /// The hunt's current progress, shown in place of the Re-run button
  /// while it runs.
  final HoleHuntProgress? progress;

  /// Set when the trick search could not run (Maia unavailable), to explain
  /// a thinner report than the settings promised.
  final bool probesSkipped;

  final void Function(AuditFinding finding)? onFindingSelected;
  final void Function(AuditResult result)? onResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHunt;

  /// Lets the host screen step the selection (previous/next shortcuts).
  final ListNavController? navController;

  @override
  State<HolesReportPanel> createState() => _HolesReportPanelState();
}

class _HolesReportPanelState extends State<HolesReportPanel>
    implements ListNavTarget {
  static const int _defaultCap = 10;
  static const double _itemExtent = 56.0;
  static const String _skippedMessage =
      'Trick search skipped — Maia unavailable';

  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _capCtrl = TextEditingController(
    text: '$_defaultCap',
  );

  /// Empty = no filtering.
  final Set<_Filter> _activeFilters = {};
  int _maxVisible = _defaultCap;

  /// [AuditFinding.dismissKey] of the selected finding — the list re-ranks
  /// as findings stream in, so a raw index would drift.
  String? _selectedKey;

  @override
  void initState() {
    super.initState();
    widget.navController?.attach(this);
  }

  @override
  void didUpdateWidget(HolesReportPanel old) {
    super.didUpdateWidget(old);
    if (!identical(widget.navController, old.navController)) {
      old.navController?.detach(this);
      widget.navController?.attach(this);
    }
  }

  @override
  void dispose() {
    widget.navController?.detach(this);
    _scrollController.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  @override
  void stepNext() => _step(1);

  @override
  void stepPrevious() => _step(-1);

  /// Move the selection [delta] rows through the ranked list, exactly as a
  /// click would (board jump included). With no current selection any step
  /// selects the top finding.
  void _step(int delta) {
    final findings = _visibleFindings();
    if (findings.isEmpty) return;
    final current = findings.indexWhere((f) => f.dismissKey == _selectedKey);
    final target = current < 0
        ? 0
        : (current + delta).clamp(0, findings.length - 1);
    if (target == current) return;
    final finding = findings[target];
    setState(() => _selectedKey = finding.dismissKey);
    widget.onFindingSelected?.call(finding);
    ensureRowVisible(_scrollController, target, _itemExtent);
  }

  List<AuditFinding> get _allFindings => [
    ...(widget.result?.findings ?? const <AuditFinding>[]),
    ...widget.liveFindings,
  ];

  bool _matchesFilters(AuditFinding f) {
    if (f.dismissed) return false;
    if (_activeFilters.isEmpty) return true;
    return _activeFilters.any((filter) => filter.matches(f));
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

  void _publishResultChange() {
    final result = widget.result;
    if (result != null) widget.onResultChanged?.call(result);
  }

  void _toggleDismiss(AuditFinding finding) {
    setState(() => finding.dismissed = !finding.dismissed);
    _publishResultChange();
  }

  void _dismissAllMatching(_Filter filter) {
    setState(() {
      for (final f in _allFindings) {
        if (filter.matches(f)) f.dismissed = true;
      }
    });
    _publishResultChange();
  }

  void _restoreAll() {
    setState(() {
      for (final f in _allFindings) {
        f.dismissed = false;
      }
    });
    _publishResultChange();
  }

  int _countOf(_Filter filter) =>
      _allFindings.where((f) => filter.matches(f) && !f.dismissed).length;

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

  String? _gainLabelOf(AuditFinding f) {
    final cp = holeGainCp(f);
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
        _buildNavRow(findings),
        const Divider(height: 1),
        Expanded(
          child: findings.isEmpty
              ? Center(
                  child: Text(
                    widget.isHunting
                        ? 'Hunting for holes...'
                        : 'No holes match the current filters',
                    style: AppTextStyles.caption,
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: findings.length,
                  itemExtent: _itemExtent,
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
                      onContextMenu: (pos) =>
                          unawaited(_showDismissMenu(pos, finding)),
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
                Text('$dismissedCount dismissed', style: AppTextStyles.caption),
                const Spacer(),
                TextButton(
                  onPressed: _restoreAll,
                  child: const Text(
                    'Restore all',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Prev/Next stepping over the ranked list. Counter only while a finding
  /// is selected — the status row above already shows the plain count.
  Widget _buildNavRow(List<AuditFinding> findings) {
    final selectedIndex = findings.indexWhere(
      (f) => f.dismissKey == _selectedKey,
    );
    return ListNavRow(
      itemLabel: 'finding',
      canPrevious: selectedIndex > 0,
      canNext: findings.isNotEmpty && selectedIndex < findings.length - 1,
      onPrevious: stepPrevious,
      onNext: stepNext,
      counterText: selectedIndex >= 0
          ? '${selectedIndex + 1} of ${findings.length}'
          : null,
    );
  }

  Widget _buildChipsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [for (final f in _filters) _filterChip(f)],
      ),
    );
  }

  Widget _buildStatusRow({
    required int visibleCount,
    required int totalMatching,
  }) {
    final progressMessage = widget.progress?.message;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            if (totalMatching > visibleCount) ...[
              const Text('Top', style: AppTextStyles.caption),
              const SizedBox(width: 3),
              SizedBox(
                width: 34,
                height: 20,
                child: VisibleCapField(
                  controller: _capCtrl,
                  onApply: _applyCapFromField,
                ),
              ),
              const SizedBox(width: 3),
              Text('of $totalMatching', style: AppTextStyles.caption),
            ] else
              Text('$visibleCount findings', style: AppTextStyles.caption),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Fixed-width slot so the Re-run button never shifts when
                  // the skipped-pass note appears.
                  SizedBox(
                    width: 22,
                    child: widget.probesSkipped
                        ? const Tooltip(
                            message: _skippedMessage,
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: AppColors.warning,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 4),
                  if (widget.isHunting && progressMessage != null)
                    Flexible(
                      child: Text(
                        progressMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption,
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(_Filter filter) {
    final selected = _activeFilters.contains(filter);
    final count = _countOf(filter);
    return SizedBox(
      height: 26,
      child: FilterChip(
        label: Text(
          '${filter.label} ($count)',
          style: const TextStyle(fontSize: 12),
        ),
        selected: selected,
        // Disabled at zero; stays live while selected so it can be
        // toggled back off.
        onSelected: (count > 0 || selected)
            ? (v) => setState(() {
                if (v) {
                  _activeFilters.add(filter);
                } else {
                  _activeFilters.remove(filter);
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

  Future<void> _showDismissMenu(Offset position, AuditFinding finding) async {
    // The chips are one per finding type, so at most one matches; a finding
    // of some other type simply gets no bulk option.
    final filter = _filters.where((f) => f.matches(finding)).firstOrNull;
    final value = await showAnchorMenu<String>(
      context: context,
      position: position,
      items: [
        compactMenuItem('dismiss', finding.dismissed ? 'Restore' : 'Dismiss'),
        if (filter != null)
          compactMenuItem('kind', 'Dismiss all ${filter.dismissAllLabel}'),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'dismiss':
        _toggleDismiss(finding);
      case 'kind':
        if (filter != null) _dismissAllMatching(filter);
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.gps_fixed, size: 40, color: AppColors.onSurfaceDim),
          const SizedBox(height: 12),
          Text(
            'No hole report yet',
            style: AppTextStyles.caption.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Find Holes attacks these lines from the opposite side: strong '
            'replies the games never answer, moves with a verified '
            'refutation, and tricks — near-best moves and novelties that '
            'score better in practice than the engine move. Ranked into a '
            'short list of killer holes. Different from Analyze with Engine, '
            'which only colors positions by raw Stockfish eval.',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption,
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
