/// Ranked trick-hunt report for the Tricks tab.
///
/// Same deliberately lean shape as the holes report panel: a flat list
/// sorted by exploit score (reach probability × net gain), capped to a
/// handful of killer tricks, with novelty/in-game filter chips and simple
/// dismissal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../../../widgets/common/list_nav.dart';
import '../../audit/models/audit_finding.dart';
import '../../audit/models/audit_result.dart';
import '../../audit/widgets/finding_style.dart';
import '../../audit/widgets/finding_tile.dart';
import '../../holes/services/hole_scoring.dart';
import '../services/trick_hunt_service.dart';

class TricksReportPanel extends StatefulWidget {
  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isHunting;
  final TrickHuntProgress? progress;

  /// Show the "probes skipped" note (Maia unavailable).
  final bool probesSkipped;

  final void Function(AuditFinding finding)? onFindingSelected;
  final void Function(AuditResult result)? onResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHunt;

  /// Lets the host screen step the selection (↓/↑ shortcuts).
  final ListNavController? navController;

  const TricksReportPanel({
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

  @override
  State<TricksReportPanel> createState() => _TricksReportPanelState();
}

class _TricksReportPanelState extends State<TricksReportPanel>
    implements ListNavTarget {
  static const int _defaultCap = 10;
  static const double _itemExtent = 56.0;

  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _capCtrl = TextEditingController(
    text: '$_defaultCap',
  );

  /// Empty = both kinds; true = novelties, false = moves in their games.
  final Set<bool> _activeFilters = {};
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
  void didUpdateWidget(TricksReportPanel old) {
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

  static bool _isNovelty(AuditFinding f) => f.isNovelty == true;

  bool _matchesFilters(AuditFinding f) {
    if (f.dismissed) return false;
    if (_activeFilters.isNotEmpty && !_activeFilters.contains(_isNovelty(f))) {
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

  void _dismissAllOfKind(bool novelty) {
    setState(() {
      for (final f in _allFindings) {
        if (_isNovelty(f) == novelty) f.dismissed = true;
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

  int _countOf(bool novelty) => _allFindings
      .where((f) => _isNovelty(f) == novelty && !f.dismissed)
      .length;

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
    return f.netGainCp;
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
        _buildNavRow(findings),
        const Divider(height: 1),
        Expanded(
          child: findings.isEmpty
              ? Center(
                  child: Text(
                    widget.isHunting
                        ? 'Hunting for tricks...'
                        : 'No tricks match the current filters',
                    style: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 12,
                    ),
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
        children: [
          _filterChip('Novelties', true),
          _filterChip('In their games', false),
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
                  // the probes-skipped note appears.
                  SizedBox(
                    width: 22,
                    child: widget.probesSkipped
                        ? const Tooltip(
                            message: 'Trick probes skipped — Maia unavailable',
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

  /// Visible-cap editor, same recipe as the holes panel: digits only,
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

  Widget _filterChip(String label, bool novelty) {
    final selected = _activeFilters.contains(novelty);
    final count = _countOf(novelty);
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
                  _activeFilters.add(novelty);
                } else {
                  _activeFilters.remove(novelty);
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
    final novelty = _isNovelty(finding);
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
          value: 'kind',
          child: Text(
            novelty ? 'Dismiss all novelties' : 'Dismiss all in-game tricks',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'dismiss':
          _toggleDismiss(finding);
        case 'kind':
          _dismissAllOfKind(novelty);
      }
    });
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.auto_fix_high,
            size: 40,
            color: AppColors.onSurfaceDim,
          ),
          const SizedBox(height: 12),
          const Text(
            'No trick report yet',
            style: TextStyle(
              color: AppColors.onSurfaceSoft,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Find Tricks plays the opposite side of these games and hunts '
            'for near-best moves and novelties that score better in '
            'practice than the engine-best move, because the likely '
            'replies run into trouble a few moves deeper. Different from '
            'Find Holes, which attacks only what the games already play.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (widget.onStartHunt != null)
            OutlinedButton.icon(
              onPressed: widget.onStartHunt,
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Find Tricks'),
            ),
        ],
      ),
    );
  }
}
