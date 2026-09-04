/// The ranked report a hunt produces: a flat list of findings sorted by
/// exploit score, capped to a handful of the best, with filter chips, simple
/// dismissal and prev/next stepping.
///
/// Deliberately leaner than the full audit findings panel, and shared by the
/// hole hunt and the trick hunt — which had a copy each. The copies ran to
/// 545 and 540 lines and were about three quarters identical: same ranking,
/// same visible-cap editor, same selection-by-key, same dismissal, same
/// context menu, same status row. What actually differed was small enough to
/// be arguments:
///
/// * what the filter chips filter *by* (holes split by finding type, tricks
///   by whether the move is a novelty) — generalised here to a named
///   predicate, which is simpler than either;
/// * how a finding's gain is recovered when the stored exploit score cannot
///   supply it;
/// * the words: the noun, the empty state, the warning when a pass was
///   skipped.
///
/// The progress object is *not* a parameter: both callers only ever read
/// `progress.message`, so this takes the message.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/anchor_menu.dart';
import '../../../widgets/common/list_nav.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/exploit_ranking.dart';
import 'finding_style.dart';
import 'finding_tile.dart';
import 'hunt_controls.dart';

/// One filter chip: a name, what it matches, and what dismissing everything
/// it matches should be called in the context menu.
class HuntFilter {
  const HuntFilter({
    required this.label,
    required this.matches,
    required this.dismissAllLabel,
  });

  /// Chip text; the live count is appended.
  final String label;

  final bool Function(AuditFinding finding) matches;

  /// Menu wording, e.g. `Dismiss all refutations`. The chip label alone
  /// reads wrong there ("Dismiss all Refutations (3)").
  final String dismissAllLabel;
}

/// What to show before a hunt has ever run.
class HuntEmptyState {
  const HuntEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
  });

  final IconData icon;
  final String title;

  /// What this hunt does and how it differs from the neighbouring one — the
  /// only place the two are explained side by side.
  final String body;

  final String actionLabel;
}

class HuntReportPanel extends StatefulWidget {
  const HuntReportPanel({
    super.key,
    required this.noun,
    required this.filters,
    required this.gainCpOf,
    required this.emptyState,
    required this.result,
    required this.liveFindings,
    required this.isHunting,
    this.progressMessage,
    this.skippedPassTooltip,
    this.onFindingSelected,
    this.onResultChanged,
    this.onStartHunt,
    this.navController,
  });

  /// Plural noun for this hunt's findings: "holes", "tricks". Used in the
  /// running and no-match lines.
  final String noun;

  final List<HuntFilter> filters;

  /// A finding's gain in centipawns, for the tile's `+1.4` label. Returns
  /// null when it cannot be derived, and the label is then omitted.
  final int? Function(AuditFinding finding) gainCpOf;

  final HuntEmptyState emptyState;

  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isHunting;

  /// The hunt's current progress line, shown in place of the Re-run button
  /// while it runs.
  final String? progressMessage;

  /// Set when part of the hunt could not run (Maia unavailable), to explain
  /// a thinner report than the settings promised.
  final String? skippedPassTooltip;

  final void Function(AuditFinding finding)? onFindingSelected;
  final void Function(AuditResult result)? onResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHunt;

  /// Lets the host screen step the selection (previous/next shortcuts).
  final ListNavController? navController;

  @override
  State<HuntReportPanel> createState() => _HuntReportPanelState();
}

class _HuntReportPanelState extends State<HuntReportPanel>
    implements ListNavTarget {
  static const int _defaultCap = 10;
  static const double _itemExtent = 56.0;

  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _capCtrl = TextEditingController(
    text: '$_defaultCap',
  );

  /// Empty = no filtering. Holds filter *labels*, not the [HuntFilter]
  /// objects: the host rebuilds those on every frame, so an identity set
  /// would empty itself on the next rebuild and quietly drop the filter
  /// while leaving the chip looking pressed. Labels are what the chips are
  /// keyed by on screen, so they are the right identity here too.
  final Set<String> _activeFilterLabels = {};

  Iterable<HuntFilter> get _activeFilters =>
      widget.filters.where((f) => _activeFilterLabels.contains(f.label));
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
  void didUpdateWidget(HuntReportPanel old) {
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
    if (_activeFilterLabels.isEmpty) return true;
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

  void _dismissAllMatching(HuntFilter filter) {
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

  int _countOf(HuntFilter filter) =>
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
    final cp = widget.gainCpOf(f);
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
                        ? 'Hunting for ${widget.noun}...'
                        : 'No ${widget.noun} match the current filters',
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
        children: [for (final f in widget.filters) _filterChip(f)],
      ),
    );
  }

  Widget _buildStatusRow({
    required int visibleCount,
    required int totalMatching,
  }) {
    final progressMessage = widget.progressMessage;
    final skipped = widget.skippedPassTooltip;
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
                    child: skipped == null
                        ? null
                        : Tooltip(
                            message: skipped,
                            child: const Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: AppColors.warning,
                            ),
                          ),
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

  Widget _filterChip(HuntFilter filter) {
    final selected = _activeFilterLabels.contains(filter.label);
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
                  _activeFilterLabels.add(filter.label);
                } else {
                  _activeFilterLabels.remove(filter.label);
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
    // The first filter this finding matches is the one "dismiss all like
    // this" acts on; the chips are mutually exclusive in both hunts today,
    // and a finding matching none simply gets no bulk option.
    final filter = widget.filters.where((f) => f.matches(finding)).firstOrNull;
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
    final empty = widget.emptyState;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(empty.icon, size: 40, color: AppColors.onSurfaceDim),
          const SizedBox(height: 12),
          Text(
            empty.title,
            style: AppTextStyles.caption.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            empty.body,
            textAlign: TextAlign.center,
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 16),
          if (widget.onStartHunt != null)
            OutlinedButton.icon(
              onPressed: widget.onStartHunt,
              icon: Icon(empty.icon, size: 16),
              label: Text(empty.actionLabel),
            ),
        ],
      ),
    );
  }
}
