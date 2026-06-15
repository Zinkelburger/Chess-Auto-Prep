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

import '../../../theme/app_colors.dart';
import '../../../utils/keyboard_shortcut_utils.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/audit_persistence.dart';

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

  void _recomputeVisible() {
    final allFindings = widget.result?.findings ?? widget.liveFindings;

    var filtered = allFindings.where((f) {
      if (_hideDismissed && f.dismissed) return false;
      if (_activeFilters.isNotEmpty && !_activeFilters.contains(f.type)) {
        return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) =>
        (b.cumulativeProbability ?? 0).compareTo(a.cumulativeProbability ?? 0));

    // Auto-scale: cap at _maxVisible so the list never overwhelms.
    // As the user dismisses items, lower-probability findings surface.
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
    return allFindings.where((f) {
      if (_hideDismissed && f.dismissed) return false;
      if (_activeFilters.isNotEmpty && !_activeFilters.contains(f.type)) {
        return false;
      }
      return true;
    }).length;
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
            _buildResumeBanner(widget.interruptedSnapshot!),
          _buildFilterBar(),
          _buildStatusRow(),
          const Divider(height: 1),
          Expanded(child: _buildFindingsList()),
          _buildDismissedSection(),
        ],
      ),
    );
  }

  // ── Resume banner ───────────────────────────────────────────────────

  Widget _buildResumeBanner(AuditSnapshot snapshot) {
    final checked = snapshot.result.nodesChecked;
    final findings = snapshot.result.findings.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.withAlpha(20),
        border: Border(
          bottom: BorderSide(color: Colors.amber.withAlpha(60)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_outline, size: 16, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Audit interrupted at $checked positions ($findings findings)',
              style: const TextStyle(fontSize: 11, color: Colors.amber),
            ),
          ),
          TextButton(
            onPressed: widget.onResumeAudit,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text('Resume'),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: widget.onStartFreshAudit,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 11),
              foregroundColor: Colors.grey,
            ),
            child: const Text('Start Fresh'),
          ),
        ],
      ),
    );
  }

  // ── Filter bar ──────────────────────────────────────────────────────

  Widget _buildFilterBar() {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    if (allFindings.isEmpty) return const SizedBox.shrink();

    int countOf(AuditFindingType t) =>
        allFindings.where((f) => f.type == t && !f.dismissed).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _filterChip(
              label: 'Blunders',
              count: countOf(AuditFindingType.mistake),
              type: AuditFindingType.mistake,
              color: AppColors.evalNegative,
            ),
            const SizedBox(width: 4),
            _filterChip(
              label: 'Inaccuracies',
              count: countOf(AuditFindingType.inaccuracy),
              type: AuditFindingType.inaccuracy,
              color: Colors.orange,
            ),
            const SizedBox(width: 4),
            _filterChip(
              label: 'Missing',
              count: countOf(AuditFindingType.missingResponse),
              type: AuditFindingType.missingResponse,
              color: Colors.blue,
            ),
            const SizedBox(width: 4),
            _filterChip(
              label: 'Weak',
              count: countOf(AuditFindingType.weakPosition),
              type: AuditFindingType.weakPosition,
              color: Colors.deepOrange,
            ),
            const SizedBox(width: 4),
            _filterChip(
              label: 'Dead Ends',
              count: countOf(AuditFindingType.deadEnd),
              type: AuditFindingType.deadEnd,
              color: AppColors.onSurfaceMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required int count,
    required AuditFindingType type,
    required Color color,
  }) {
    final isActive = _activeFilters.contains(type);
    return FilterChip(
      label: Text(
        count > 0 ? '$label ($count)' : label,
        style: TextStyle(
          fontSize: 12,
          color: isActive ? Colors.white : color,
        ),
      ),
      selected: isActive,
      selectedColor: color.withAlpha(80),
      backgroundColor: Colors.transparent,
      side: BorderSide(
        color: isActive ? color : color.withAlpha(60),
        width: 1,
      ),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      onSelected: count > 0 ? (_) => _toggleFilter(type) : null,
    );
  }

  // ── Status row (position counter + dismissed toggle) ──────────────────

  Widget _buildStatusRow() {
    final checked = widget.auditNodesChecked;
    final total = widget.auditTotalNodes;
    final progressFraction = total > 0 ? checked / total : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.isAuditing && total > 0)
          LinearProgressIndicator(
            value: progressFraction,
            minHeight: 2,
            backgroundColor: Colors.grey[800],
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              if (widget.isAuditing) ...[
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.grey[500],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  total > 0
                      ? '$checked / $total positions · ${_visibleFindings.length} findings'
                      : 'Starting audit...',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ] else ...[
                if (_totalMatchingFindings > _visibleFindings.length) ...[
                  Text('Top',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                  const SizedBox(width: 3),
                  SizedBox(
                    width: 34,
                    height: 20,
                    child: TextField(
                      controller: _capController,
                      style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Colors.grey[700]!, width: 0.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Colors.grey[700]!, width: 0.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              BorderSide(color: Colors.grey[500]!, width: 1),
                        ),
                      ),
                      onSubmitted: (_) => _applyCapFromField(),
                      onTapOutside: (_) {
                        _applyCapFromField();
                        FocusScope.of(context).unfocus();
                      },
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text('of $_totalMatchingFindings',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                  if (_reachThreshold != null) ...[
                    const SizedBox(width: 4),
                    Text('· ≥ $_reachThreshold reach',
                        style: TextStyle(
                            fontSize: 11, color: Colors.blueGrey[300])),
                  ],
                ] else ...[
                  Text('${_visibleFindings.length} findings',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                  if (widget.result?.timestamp != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· ${_formatTimestamp(widget.result!.timestamp!)}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ],
                ],
              ],
              if (_selectedIndex >= 0 && _visibleFindings.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  '${_selectedIndex + 1} of ${_visibleFindings.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
              const Spacer(),
              if (widget.onRerunAudit != null)
                Tooltip(
                  message: 'New audit with different settings',
                  child: IconButton(
                    icon:
                        const Icon(Icons.refresh, size: 14, color: Colors.grey),
                    onPressed: widget.onRerunAudit,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 24, minHeight: 24),
                  ),
                ),
              Tooltip(
                message: _hideDismissed ? 'Show dismissed' : 'Hide dismissed',
                child: IconButton(
                  icon: Icon(
                    _hideDismissed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 14,
                    color: Colors.grey,
                  ),
                  onPressed: () {
                    setState(() {
                      _hideDismissed = !_hideDismissed;
                      _recomputeVisible();
                    });
                  },
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Findings list ─────────────────────────────────────────────────────

  Widget _buildFindingsList() {
    if (_visibleFindings.isEmpty) {
      if (widget.isAuditing) {
        return Center(
          child: Text('Auditing...',
              style: TextStyle(color: Colors.grey[500], fontSize: 12)),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined, size: 40, color: Colors.grey[700]),
            const SizedBox(height: 12),
            Text('No audit findings',
                style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Run an audit to check your repertoire for gaps, '
              'weak moves, and missing responses.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (widget.onStartAudit != null)
              OutlinedButton.icon(
                onPressed: widget.onStartAudit,
                icon: const Icon(Icons.policy_outlined, size: 16),
                label: const Text('Start Audit'),
              ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _visibleFindings.length,
      itemExtent: 56,
      itemBuilder: (context, index) {
        final finding = _visibleFindings[index];
        final isSelected = index == _selectedIndex;
        return _buildFindingTile(finding, index, isSelected);
      },
    );
  }

  Widget _buildFindingTile(AuditFinding finding, int index, bool isSelected) {
    final color = _findingColor(finding);
    final icon = _findingIcon(finding);

    return GestureDetector(
      onSecondaryTapUp: (details) {
        _showDismissMenu(context, details.globalPosition, finding);
      },
      child: Material(
        color: isSelected
            ? Theme.of(context).colorScheme.primaryContainer.withAlpha(60)
            : Colors.transparent,
        child: InkWell(
          onTap: () => _selectFinding(index),
          onLongPress: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null) {
              final pos = box.localToGlobal(Offset.zero);
              _showDismissMenu(context, Offset(pos.dx + 100, pos.dy), finding);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 6),
                if (finding.reachProbLabel != null) ...[
                  SizedBox(
                    width: 48,
                    child: Text(
                      finding.reachProbLabel!,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: finding.dismissed
                            ? Colors.grey[700]
                            : Colors.blueGrey[300],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        finding.summary,
                        style: TextStyle(
                          fontSize: 12,
                          color: finding.dismissed ? Colors.grey : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        finding.movePathString,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    finding.dismissed ? Icons.undo : Icons.close,
                    size: 16,
                    color: finding.dismissed ? Colors.grey : Colors.grey[400],
                  ),
                  tooltip: finding.dismissed ? 'Restore' : 'Dismiss (D)',
                  onPressed: () {
                    setState(() {
                      _dismissFinding(finding);
                      _recomputeVisible();
                    });
                  },
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  hoverColor: Colors.grey.withAlpha(40),
                  splashRadius: 16,
                ),
              ],
            ),
          ),
        ),
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

  // ── Dismissed section ─────────────────────────────────────────────────

  Widget _buildDismissedSection() {
    final allFindings = widget.result?.findings ?? widget.liveFindings;
    final dismissedCount = allFindings.where((f) => f.dismissed).length;
    if (dismissedCount == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.archive_outlined, size: 14, color: Colors.grey[500]),
          const SizedBox(width: 4),
          Text(
            '$dismissedCount dismissed',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const Spacer(),
          TextButton(
            onPressed: _restoreAll,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 20),
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text('Restore all'),
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Color _findingColor(AuditFinding finding) {
    return switch (finding.type) {
      AuditFindingType.mistake => AppColors.evalNegative,
      AuditFindingType.inaccuracy => Colors.orange,
      AuditFindingType.missingResponse => Colors.blue,
      AuditFindingType.weakPosition => Colors.deepOrange,
      AuditFindingType.deadEnd => AppColors.onSurfaceMuted,
    };
  }

  String _formatTimestamp(DateTime ts) {
    final now = DateTime.now();
    final diff = now.difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${ts.month}/${ts.day}';
  }

  IconData _findingIcon(AuditFinding finding) {
    return switch (finding.type) {
      AuditFindingType.mistake => Icons.error_outline,
      AuditFindingType.inaccuracy => Icons.warning_amber_outlined,
      AuditFindingType.missingResponse => Icons.visibility_off_outlined,
      AuditFindingType.weakPosition => Icons.trending_down,
      AuditFindingType.deadEnd => Icons.block_outlined,
    };
  }
}
