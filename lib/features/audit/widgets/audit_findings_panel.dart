/// Audit findings display — summary card, findings list, bulk dismiss,
/// keyboard navigation, and selected-state highlighting.
///
/// Lives in the bottom pane Findings tab. Receives results from the screen
/// state; does not own the audit service. Findings are sorted by reach
/// probability (cumulative likelihood of the line occurring) and capped at
/// a user-configurable limit (default 20). As the user dismisses findings,
/// lower-probability ones surface automatically.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../utils/keyboard_shortcut_utils.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/audit_persistence.dart';
import 'audit_dismissed_section.dart';
import 'audit_filter_bar.dart';
import 'audit_findings_list.dart';
import 'audit_resume_banner.dart';
import 'audit_status_row.dart';

class AuditFindingsPanel extends StatefulWidget {
  final AuditResult? result;
  final List<AuditFinding> liveFindings;
  final bool isAuditing;
  final int auditNodesChecked;
  final int auditTotalNodes;

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
    final allFindings = widget.result?.findings ?? widget.liveFindings;

    var filtered = allFindings.where(_matchesFilters).toList();

    filtered.sort((a, b) =>
        (b.cumulativeProbability ?? 0).compareTo(a.cumulativeProbability ?? 0));

    if (filtered.length > _maxVisible) {
      _visibleFindings = filtered.sublist(0, _maxVisible);
    } else {
      _visibleFindings = filtered;
    }

    if (_selectedIndex >= _visibleFindings.length) {
      _selectedIndex = _visibleFindings.isEmpty ? -1 : 0;
    }
  }

  /// Total findings that match the current type filter (regardless of auto-scale cap).
  int get _totalMatchingFindings {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    return allFindings.where(_matchesFilters).length;
  }

  void _applyCapFromField() {
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
    setState(() {
      _activeFilters.clear();
      if (type != null) _activeFilters.add(type);
      _selectedIndex = -1;
      _recomputeVisible();
    });
  }

  void _toggleFilter(AuditFindingType type) {
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
      _scrollController.animateTo(offset,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    } else if (offset + itemHeight > viewEnd) {
      _scrollController.animateTo(offset + itemHeight - viewEnd + viewStart,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  void _dismissCurrent() {
    if (_selectedIndex < 0 || _selectedIndex >= _visibleFindings.length) return;
    final finding = _visibleFindings[_selectedIndex];
    _dismissFinding(finding);
    _recomputeVisible();
    if (_selectedIndex >= _visibleFindings.length &&
        _visibleFindings.isNotEmpty) {
      _selectedIndex = _visibleFindings.length - 1;
    }
    if (_visibleFindings.isNotEmpty && _selectedIndex >= 0) {
      _navigateToFinding(_visibleFindings[_selectedIndex]);
    }
    setState(() {});
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (isTextInputFocused()) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyN ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_selectedIndex < _visibleFindings.length - 1) {
        _selectFinding(_selectedIndex + 1);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyP ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_selectedIndex > 0) {
        _selectFinding(_selectedIndex - 1);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyD && hasNoLetterModifiers) {
      _dismissCurrent();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

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

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasData = widget.result != null || widget.liveFindings.isNotEmpty;

    if (!hasData && !widget.isAuditing) {
      return const Center(
        child: Text(
          'No audit results yet.\nRun an audit from the toolbar (A).',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    return Focus(
      focusNode: _listFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          if (widget.interruptedSnapshot != null && !widget.isAuditing)
            AuditResumeBanner(
              snapshot: widget.interruptedSnapshot!,
              onResume: widget.onResumeAudit,
              onStartFresh: widget.onStartFreshAudit,
            ),
          AuditFilterBar(
            findings: widget.result?.findings ?? widget.liveFindings,
            activeFilters: _activeFilters,
            onToggle: _toggleFilter,
            clashOnly: _clashOnly,
            onToggleClashOnly: () {
              setState(() {
                _clashOnly = !_clashOnly;
                _selectedIndex = -1;
                _recomputeVisible();
              });
            },
          ),
          AuditStatusRow(
            isAuditing: widget.isAuditing,
            nodesChecked: widget.auditNodesChecked,
            totalNodes: widget.auditTotalNodes,
            visibleCount: _visibleFindings.length,
            totalMatching: _totalMatchingFindings,
            selectedIndex: _selectedIndex,
            hideDismissed: _hideDismissed,
            capController: _capController,
            reachThreshold: _reachThreshold,
            resultTimestamp: widget.result?.timestamp,
            onRerunAudit: widget.onRerunAudit,
            onApplyCap: _applyCapFromField,
            onToggleHideDismissed: () {
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
              onStartAudit: widget.onStartAudit,
              onSelect: _selectFinding,
              onToggleDismiss: (finding) {
                setState(() {
                  _dismissFinding(finding);
                  _recomputeVisible();
                });
              },
              onContextMenu: (finding, pos) =>
                  _showDismissMenu(context, pos, finding),
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

  void _showDismissMenu(
      BuildContext context, Offset position, AuditFinding finding) {
    final plyLabel = finding.movePath.isEmpty
        ? 'root'
        : 'move ${(finding.movePath.length + 1) ~/ 2}';
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        PopupMenuItem(
          value: 'dismiss',
          child: Text(finding.dismissed ? 'Restore' : 'Dismiss',
              style: const TextStyle(fontSize: 12)),
        ),
        const PopupMenuItem(
          value: 'similar',
          child: Text('Dismiss similar at this position',
              style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'depth',
          child: Text(
              'Dismiss all ${finding.type.name} at $plyLabel or earlier',
              style: const TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'type',
          child: Text('Dismiss all ${_typeLabel(finding.type)}',
              style: const TextStyle(fontSize: 12)),
        ),
      ],
    ).then((value) {
      if (value == null) return;
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
    });
  }

  String _typeLabel(AuditFindingType type) {
    return switch (type) {
      AuditFindingType.mistake => 'mistakes',
      AuditFindingType.inaccuracy => 'inaccuracies',
      AuditFindingType.missingResponse => 'missing responses',
      AuditFindingType.weakPosition => 'weak positions',
      AuditFindingType.deadEnd => 'dead ends',
    };
  }

}
