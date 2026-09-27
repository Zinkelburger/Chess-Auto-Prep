/// Audit findings display — summary card, findings list, bulk dismiss,
/// keyboard navigation, and selected-state highlighting.
///
/// Lives in the bottom pane Findings tab. Receives results from the screen
/// state; does not own the audit service. Findings are searchable, sorted by
/// severity by default (or estimated frequency), and capped at a configurable
/// limit. Dismissing findings brings the next items into the review queue.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../design_system/components/list_search_field.dart';
import '../services/audit_config.dart';
import '../../../utils/app_shortcuts.dart';
import '../../../utils/keyboard_shortcut_utils.dart';
import '../../../widgets/common/anchor_menu.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/audit_persistence.dart';
import 'audit_dismissed_section.dart';
import 'audit_filter_bar.dart';
import 'audit_findings_list.dart';
import 'audit_resume_banner.dart';
import 'audit_status_row.dart';
import 'hunt_controls.dart';

class AuditFindingsPanel extends StatefulWidget {
  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isAuditing;
  final int auditNodesChecked;
  final int auditTotalNodes;
  final String? errorText;
  final String? chapterName;
  final bool subtreeOnly;
  final AuditConfig? config;

  /// Called when a finding is selected. Passes the full finding so the screen
  /// can handle ephemeral missing-move preview, navigation, etc.
  final void Function(AuditFinding finding)? onFindingSelected;

  final void Function(AuditResult updatedResult)? onResultChanged;
  final VoidCallback? onRerunAudit;

  final AuditSnapshot? interruptedSnapshot;
  final VoidCallback? onResumeAudit;
  final VoidCallback? onStartFreshAudit;
  final VoidCallback? onStartAudit;

  const AuditFindingsPanel({
    super.key,
    this.result,
    this.liveFindings = const [],
    this.isAuditing = false,
    this.auditNodesChecked = 0,
    this.auditTotalNodes = 0,
    this.errorText,
    this.chapterName,
    this.subtreeOnly = false,
    this.config,
    this.onFindingSelected,
    this.onResultChanged,
    this.onRerunAudit,
    this.interruptedSnapshot,
    this.onResumeAudit,
    this.onStartFreshAudit,
    this.onStartAudit,
  });

  @override
  State<AuditFindingsPanel> createState() => AuditFindingsPanelState();
}

class AuditFindingsPanelState extends State<AuditFindingsPanel> {
  int _selectedIndex = -1;
  String _search = '';
  bool _sortByFrequency = false;
  bool _hideDismissed = true;

  /// Active type filters. Empty set = show all types.
  final Set<AuditFindingType> _activeFilters = {};

  /// When true, only clash-sourced missing responses are shown.
  bool _clashOnly = false;

  /// Max visible findings at once (user-configurable).
  int _maxVisible = 20;
  late final TextEditingController _capController;

  final ScrollController _scrollController = ScrollController();
  final FocusNode _listFocusNode = FocusNode();

  List<AuditFinding> _visibleFindings = [];

  @override
  void initState() {
    super.initState();
    _capController = TextEditingController(text: '$_maxVisible');
    _recomputeVisible();
  }

  @override
  void didUpdateWidget(AuditFindingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result ||
        oldWidget.liveFindings != widget.liveFindings) {
      _recomputeVisible();
    }
  }

  @override
  void dispose() {
    _capController.dispose();
    _scrollController.dispose();
    _listFocusNode.dispose();
    super.dispose();
  }

  bool _matchesFilters(AuditFinding f) {
    if (_hideDismissed && f.dismissed) return false;
    if (!matchesSearch(_search, '${f.summary} ${f.movePathString}')) {
      return false;
    }
    if (_activeFilters.isNotEmpty && !_activeFilters.contains(f.type)) {
      return false;
    }
    if (_clashOnly &&
        !(f.type == AuditFindingType.missingResponse &&
            f.source == MissingResponseSource.clash)) {
      return false;
    }
    return true;
  }

  void _recomputeVisible() {
    final selected =
        _selectedIndex >= 0 && _selectedIndex < _visibleFindings.length
        ? _visibleFindings[_selectedIndex]
        : null;
    final allFindings = widget.result?.findings ?? widget.liveFindings;

    var filtered = allFindings.where(_matchesFilters).toList();

    filtered.sort((a, b) {
      if (!_sortByFrequency) {
        final severity = a.severity.index.compareTo(b.severity.index);
        if (severity != 0) return severity;
      }
      final reach = (b.cumulativeProbability ?? 0).compareTo(
        a.cumulativeProbability ?? 0,
      );
      if (reach != 0) return reach;
      final loss = (b.evalLossCp ?? 0).compareTo(a.evalLossCp ?? 0);
      if (loss != 0) return loss;
      return a.dismissKey.compareTo(b.dismissKey);
    });

    if (filtered.length > _maxVisible) {
      _visibleFindings = filtered.sublist(0, _maxVisible);
    } else {
      _visibleFindings = filtered;
    }

    _selectedIndex = selected == null ? -1 : _visibleFindings.indexOf(selected);
  }

  /// Total findings that match the current type filter (regardless of auto-scale cap).
  int get _totalMatchingFindings {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    return allFindings.where(_matchesFilters).length;
  }

  void _applyCapFromField() {
    if (!mounted) return;
    final parsed = int.tryParse(_capController.text.trim());
    if (parsed == null || parsed < 1) {
      _capController.text = '$_maxVisible';
      return;
    }
    final clamped = parsed.clamp(1, 999);
    if (clamped != _maxVisible) {
      setState(() {
        _maxVisible = clamped;
        _capController.text = '$clamped';
        _recomputeVisible();
      });
    } else {
      _capController.text = '$clamped';
    }
  }

  /// Reach-probability threshold: the lowest probability in the visible batch.
  String? get _reachThreshold {
    if (_visibleFindings.isEmpty) return null;
    return _visibleFindings.last.reachProbLabel;
  }

  void setFilterType(AuditFindingType? type) {
    if (!mounted) return;
    setState(() {
      _activeFilters.clear();
      if (type != null) _activeFilters.add(type);
      _selectedIndex = -1;
      _recomputeVisible();
    });
  }

  void _toggleFilter(AuditFindingType type) {
    if (!mounted) return;
    setState(() {
      if (_activeFilters.contains(type)) {
        _activeFilters.remove(type);
      } else {
        _activeFilters.add(type);
      }
      _selectedIndex = -1;
      _recomputeVisible();
    });
  }

  /// Select next finding. Returns true if handled (findings are available).
  bool selectNext() {
    if (_visibleFindings.isEmpty) return false;
    if (_selectedIndex < _visibleFindings.length - 1) {
      _selectFinding(_selectedIndex + 1);
    }
    return true;
  }

  /// Select previous finding. Returns true if handled (findings are available).
  bool selectPrevious() {
    if (_visibleFindings.isEmpty) return false;
    if (_selectedIndex > 0) {
      _selectFinding(_selectedIndex - 1);
    }
    return true;
  }

  /// Dismiss current finding. Returns true if handled (a finding was selected).
  bool dismissSelected() {
    if (_selectedIndex < 0 || _selectedIndex >= _visibleFindings.length) {
      return false;
    }
    _dismissCurrent();
    return true;
  }

  void _selectFinding(int index) {
    if (!mounted) return;
    if (index < 0 || index >= _visibleFindings.length) return;
    setState(() => _selectedIndex = index);
    _navigateToFinding(_visibleFindings[index]);
    _ensureVisible(index);
  }

  void _navigateToFinding(AuditFinding finding) {
    widget.onFindingSelected?.call(finding);
  }

  void _ensureVisible(int index) {
    if (!_scrollController.hasClients) return;
    const itemHeight = 56.0;
    final offset = index * itemHeight;
    final viewStart = _scrollController.offset;
    final viewEnd = viewStart + _scrollController.position.viewportDimension;

    if (offset < viewStart) {
      unawaited(
        _scrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        ),
      );
    } else if (offset + itemHeight > viewEnd) {
      unawaited(
        _scrollController.animateTo(
          offset + itemHeight - viewEnd + viewStart,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  void _dismissCurrent() {
    if (_selectedIndex < 0 || _selectedIndex >= _visibleFindings.length) return;
    final index = _selectedIndex;
    final finding = _visibleFindings[index];
    _dismissFinding(finding);
    _recomputeVisible();
    _selectedIndex = _visibleFindings.isEmpty
        ? -1
        : index.clamp(0, _visibleFindings.length - 1);
    if (_selectedIndex >= 0) {
      _navigateToFinding(_visibleFindings[_selectedIndex]);
    }
    setState(() {});
  }

  /// Panel shortcuts, dispatched through [handleKeyBindings] (never while
  /// typing). The findings list is the queue in front of you, so it answers
  /// to the app-wide [AppShortcut.previousItem]/[AppShortcut.nextItem] pair.
  List<KeyBinding> get _keyBindings => [
    ...KeyBinding.forShortcut(AppShortcut.nextItem, 'Next finding', () {
      if (_selectedIndex < _visibleFindings.length - 1) {
        _selectFinding(_selectedIndex + 1);
      }
    }, repeats: true),
    ...KeyBinding.forShortcut(AppShortcut.previousItem, 'Previous finding', () {
      if (_selectedIndex > 0) {
        _selectFinding(_selectedIndex - 1);
      }
    }, repeats: true),
    ...KeyBinding.forShortcut(
      AppShortcut.dismissFinding,
      'Dismiss finding',
      _dismissCurrent,
    ),
  ];

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) =>
      handleKeyBindings(_keyBindings, event, node: node);

  // ── Bulk dismiss ──────────────────────────────────────────────────────

  void _dismissFinding(AuditFinding finding) {
    finding.dismissed = !finding.dismissed;
    _notifyResultChanged();
  }

  void _dismissSimilar(AuditFinding finding) {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    for (final f in allFindings) {
      if (f.type == finding.type && f.fen == finding.fen) {
        f.dismissed = true;
      }
    }
    _notifyResultChanged();
    _recomputeVisible();
    setState(() {});
  }

  void _dismissAtDepth(AuditFinding finding) {
    final maxPly = finding.movePath.length;
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    for (final f in allFindings) {
      if (f.movePath.length <= maxPly && f.type == finding.type) {
        f.dismissed = true;
      }
    }
    _notifyResultChanged();
    _recomputeVisible();
    setState(() {});
  }

  void _dismissAllOfType(AuditFindingType type) {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    for (final f in allFindings) {
      if (f.type == type) f.dismissed = true;
    }
    _notifyResultChanged();
    _recomputeVisible();
    setState(() {});
  }

  void _restoreAll() {
    if (!mounted) return;
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    for (final f in allFindings) {
      f.dismissed = false;
    }
    _notifyResultChanged();
    _recomputeVisible();
    setState(() {});
  }

  void _notifyResultChanged() {
    if (widget.result != null) {
      widget.onResultChanged?.call(widget.result!);
    }
  }

  int _searchReset = 0;
  void _clearFilters() {
    if (!mounted) return;
    setState(() {
      _search = '';
      _searchReset++;
      _activeFilters.clear();
      _clashOnly = false;
      _recomputeVisible();
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    final hasData =
        widget.result != null ||
        allFindings.isNotEmpty ||
        widget.interruptedSnapshot != null;
    final hasFilters =
        _search.isNotEmpty || _activeFilters.isNotEmpty || _clashOnly;
    final allDismissed =
        allFindings.isNotEmpty && allFindings.every((f) => f.dismissed);
    final warnings =
        widget.result?.warnings ??
        widget.interruptedSnapshot?.result.warnings ??
        const <String>[];
    final checked = widget.result?.nodesChecked ?? widget.auditNodesChecked;
    final emptyTitle = !hasData
        ? 'Check this chapter'
        : hasFilters
        ? 'No findings match these filters'
        : allDismissed
        ? 'All findings dismissed'
        : widget.interruptedSnapshot != null
        ? 'Audit interrupted'
        : checked == 0
        ? 'No positions checked'
        : warnings.isNotEmpty
        ? 'No findings from the available checks'
        : 'No issues found in the checked positions';
    final emptyMessage = !hasData
        ? 'Find weak repertoire moves and missing opponent replies. Select a finding to review its line on the board.'
        : hasFilters
        ? 'Clear the filters to see the rest of the report.'
        : allDismissed
        ? 'Dismissed findings are still saved. Restore them below to review again.'
        : widget.interruptedSnapshot != null
        ? 'Resume to finish checking this chapter.'
        : warnings.isNotEmpty
        ? 'Some enabled checks were unavailable. Review the notice above before relying on this result.'
        : 'Results apply to the selected scope, sources and thresholds.';

    return Focus(
      focusNode: _listFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          if (widget.chapterName != null || hasData || widget.errorText != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message:
                          widget.config?.summaryLabel ??
                          'Audit of the current chapter',
                      child: Text(
                        '${widget.chapterName ?? 'Chapter audit'}${widget.subtreeOnly ? ' · Subtree' : ''}${hasData && !widget.isAuditing ? ' · $checked positions checked' : ''}',
                        style: AppTextStyles.bodyStrong,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (warnings.isNotEmpty)
                    Tooltip(
                      message: warnings.join('\n'),
                      child: const Text(
                        'Some checks unavailable',
                        style: TextStyle(
                          color: AppColors.warning,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (widget.errorText != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                widget.errorText!,
                style: const TextStyle(color: AppColors.danger, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (widget.interruptedSnapshot != null && !widget.isAuditing)
            AuditResumeBanner(
              snapshot: widget.interruptedSnapshot!,
              onResume: widget.onResumeAudit,
              onStartFresh: widget.onStartFreshAudit,
            ),
          if (allFindings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: ListSearchField(
                      hintText: 'Find a move or line',
                      key: ValueKey(_searchReset),
                      onChanged: (value) {
                        if (!mounted) return;
                        setState(() {
                          _search = value;
                          _recomputeVisible();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message:
                        'Priority puts serious findings first. Frequency uses estimates from repertoire branch counts and source probabilities, not measured game frequency.',
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Priority')),
                        ButtonSegment(value: true, label: Text('Frequency')),
                      ],
                      selected: {_sortByFrequency},
                      onSelectionChanged: (value) {
                        if (!mounted) return;
                        setState(() {
                          _sortByFrequency = value.single;
                          _recomputeVisible();
                        });
                      },
                    ),
                  ),
                  if (hasFilters)
                    TextButton(
                      onPressed: _clearFilters,
                      child: const Text('Clear filters'),
                    ),
                ],
              ),
            ),
          AuditFilterBar(
            findings: widget.result?.findings ?? widget.liveFindings,
            activeFilters: _activeFilters,
            includeDismissed: !_hideDismissed,
            onToggle: _toggleFilter,
            clashOnly: _clashOnly,
            onToggleClashOnly: () {
              if (!mounted) return;
              setState(() {
                _clashOnly = !_clashOnly;
                _selectedIndex = -1;
                _recomputeVisible();
              });
            },
          ),
          if (hasData || widget.isAuditing)
            AuditStatusRow(
              isAuditing: widget.isAuditing,
              nodesChecked: widget.auditNodesChecked,
              totalNodes: widget.auditTotalNodes,
              visibleCount: _visibleFindings.length,
              totalMatching: _totalMatchingFindings,
              selectedIndex: _selectedIndex,
              hideDismissed: _hideDismissed,
              capController: _capController,
              reachThreshold: _sortByFrequency ? _reachThreshold : null,
              resultTimestamp: widget.result?.timestamp,
              onRerunAudit: widget.isAuditing ? null : widget.onRerunAudit,
              onApplyCap: _applyCapFromField,
              onToggleHideDismissed: () {
                if (!mounted) return;
                setState(() {
                  _hideDismissed = !_hideDismissed;
                  _recomputeVisible();
                });
              },
            ),
          const Divider(height: 1),
          Expanded(
            child: AuditFindingsList(
              findings: _visibleFindings,
              isAuditing: widget.isAuditing,
              scrollController: _scrollController,
              selectedIndex: _selectedIndex,
              emptyTitle: emptyTitle,
              emptyMessage: emptyMessage,
              emptyActionLabel: hasFilters ? 'Clear filters' : 'Start audit',
              onStartAudit: hasFilters
                  ? _clearFilters
                  : (!hasData || checked == 0)
                  ? widget.onStartAudit
                  : null,
              onSelect: _selectFinding,
              onToggleDismiss: (finding) {
                if (!mounted) return;
                setState(() {
                  _dismissFinding(finding);
                  _recomputeVisible();
                });
              },
              onContextMenu: (finding, pos) =>
                  unawaited(_showDismissMenu(context, pos, finding)),
            ),
          ),
          AuditDismissedSection(
            dismissedCount: (widget.result?.findings ?? widget.liveFindings)
                .where((f) => f.dismissed)
                .length,
            onRestoreAll: _restoreAll,
          ),
        ],
      ),
    );
  }

  // ── Dismiss context menu ──────────────────────────────────────────────

  Future<void> _showDismissMenu(
    BuildContext context,
    Offset position,
    AuditFinding finding,
  ) async {
    final plyLabel = finding.movePath.isEmpty
        ? 'root'
        : 'move ${(finding.movePath.length + 1) ~/ 2}';
    final value = await showAnchorMenu<String>(
      context: context,
      position: position,
      items: [
        compactMenuItem('dismiss', finding.dismissed ? 'Restore' : 'Dismiss'),
        compactMenuItem('similar', 'Dismiss similar at this position'),
        compactMenuItem(
          'depth',
          'Dismiss all ${finding.type.name} at $plyLabel or earlier',
        ),
        compactMenuItem('type', 'Dismiss all ${_typeLabel(finding.type)}'),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'dismiss':
        setState(() {
          _dismissFinding(finding);
          _recomputeVisible();
        });
      case 'similar':
        _dismissSimilar(finding);
      case 'depth':
        _dismissAtDepth(finding);
      case 'type':
        _dismissAllOfType(finding.type);
    }
  }

  String _typeLabel(AuditFindingType type) {
    return switch (type) {
      AuditFindingType.mistake => 'mistakes',
      AuditFindingType.inaccuracy => 'inaccuracies',
      AuditFindingType.missingResponse => 'missing responses',
      AuditFindingType.weakPosition => 'weak positions',
      AuditFindingType.deadEnd => 'dead ends',
      AuditFindingType.uncoveredStrongMove => 'uncovered strong moves',
      AuditFindingType.refutation => 'refutations',
      AuditFindingType.trickyMove => 'tricky moves',
    };
  }
}
