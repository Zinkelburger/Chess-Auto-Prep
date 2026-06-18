import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../models/tactics_position.dart';
import '../../models/tactics_session_settings.dart';
import '../../services/tactics_import_service.dart';

/// Import controls and session start UI when no tactic is active.
class TacticsImportPanel extends StatefulWidget {
  const TacticsImportPanel({
    super.key,
    this.importStatus,
    required this.isImporting,
    this.activeImport,
    required this.analyzedGameCount,
    required this.lichessUserController,
    required this.lichessCountController,
    required this.chessComUserController,
    required this.chessComCountController,
    required this.stockfishDepthController,
    required this.coresController,
    this.depthError,
    this.coresError,
    required this.importFieldsValid,
    required this.onValidateDepth,
    required this.onValidateCores,
    required this.onImportLichess,
    required this.onImportChessCom,
    required this.onDismissImportStatus,
    required this.onCancelImport,
    required this.positions,
    required this.onStartSession,
    required this.onClearDatabase,
    required this.onBrowseTactics,
    this.clearDatabaseEnabled = true,
  });

  final String? importStatus;
  final bool isImporting;
  final TacticsImportService? activeImport;
  final int analyzedGameCount;
  final TextEditingController lichessUserController;
  final TextEditingController lichessCountController;
  final TextEditingController chessComUserController;
  final TextEditingController chessComCountController;
  final TextEditingController stockfishDepthController;
  final TextEditingController coresController;
  final String? depthError;
  final String? coresError;
  final bool importFieldsValid;
  final ValueChanged<String> onValidateDepth;
  final ValueChanged<String> onValidateCores;
  final VoidCallback onImportLichess;
  final VoidCallback onImportChessCom;
  final VoidCallback onDismissImportStatus;
  final VoidCallback onCancelImport;
  final List<TacticsPosition> positions;
  final void Function(TacticsSessionSettings settings) onStartSession;
  final VoidCallback onClearDatabase;
  final VoidCallback onBrowseTactics;
  final bool clearDatabaseEnabled;

  @override
  State<TacticsImportPanel> createState() => _TacticsImportPanelState();
}

class _TacticsImportPanelState extends State<TacticsImportPanel> {
  var _settings = const TacticsSessionSettings();

  int get _matchingCount => _settings.countMatching(widget.positions);

  Future<void> _showSessionSettingsDialog() async {
    var draft = _settings;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final matching = draft.countMatching(widget.positions);
          return AlertDialog(
            title: const Text('Session Settings'),
            content: SizedBox(
              width: 360,
              child: _SessionSettingsForm(
                settings: draft,
                onChanged: (s) => setDialogState(() => draft = s),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() => _settings = draft);
                  Navigator.pop(ctx);
                },
                child: Text('Apply ($matching positions)'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// A single import-source row: username field, recent-games count field, and
  /// an Import button (enabled only when no import is in progress and fields
  /// are valid).
  Widget _buildImportSourceRow({
    required TextEditingController userController,
    required String userLabel,
    required ValueChanged<String> onUsernameChanged,
    required TextEditingController countController,
    required VoidCallback onImport,
  }) {
    final canImport = widget.importStatus == null && widget.importFieldsValid;
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: userController,
            decoration: InputDecoration(
              labelText: userLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: onUsernameChanged,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: TextField(
            controller: countController,
            decoration: const InputDecoration(
              labelText: 'Recent Games',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            keyboardType: TextInputType.number,
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: canImport ? onImport : null,
          child: const Text('Import'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final positionCount = widget.positions.length;
    final matchingCount = _matchingCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.importStatus != null) ...[
          TacticsImportStatusBanner(
            status: widget.importStatus!,
            isImporting: widget.isImporting,
            hasActiveImport: widget.activeImport != null,
            analyzedGameCount: widget.analyzedGameCount,
            onCancelImport: widget.onCancelImport,
            onDismiss: widget.onDismissImportStatus,
          ),
          const SizedBox(height: 16),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Import Games',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    children: [
                      _buildImportSourceRow(
                        userController: widget.lichessUserController,
                        userLabel: 'Lichess Username',
                        onUsernameChanged: (v) =>
                            context.read<AppState>().setLichessUsername(v),
                        countController: widget.lichessCountController,
                        onImport: widget.onImportLichess,
                      ),
                      const SizedBox(height: 12),
                      _buildImportSourceRow(
                        userController: widget.chessComUserController,
                        userLabel: 'Chess.com Username',
                        onUsernameChanged: (v) =>
                            context.read<AppState>().setChesscomUsername(v),
                        countController: widget.chessComCountController,
                        onImport: widget.onImportChessCom,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox(
                            width: 140,
                            child: TextField(
                              controller: widget.stockfishDepthController,
                              decoration: InputDecoration(
                                labelText: 'Stockfish Depth',
                                border: const OutlineInputBorder(),
                                isDense: true,
                                errorText: widget.depthError,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: widget.onValidateDepth,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 100,
                            child: TextField(
                              controller: widget.coresController,
                              enabled: TacticsImportService.isParallelAvailable,
                              decoration: InputDecoration(
                                labelText: 'Cores',
                                border: const OutlineInputBorder(),
                                isDense: true,
                                errorText: widget.coresError,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: widget.onValidateCores,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (positionCount > 0) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: matchingCount > 0
                  ? () => widget.onStartSession(_settings)
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
                backgroundColor: widget.isImporting
                    ? Colors.green[700]
                    : Theme.of(context).colorScheme.primaryContainer,
              ),
              icon: Icon(
                  widget.isImporting ? Icons.play_circle : Icons.play_arrow),
              label: Text(
                widget.isImporting
                    ? 'Start Training Now ($matchingCount positions)'
                    : 'Start Practice Session ($matchingCount positions)',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
        if (widget.isImporting && positionCount > 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.green, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You can start training now! New tactics will be added as they\'re found.',
                    style: TextStyle(fontSize: 12, color: Colors.green),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            _conditionalTooltip(
              message: positionCount == 0
                  ? 'No positions in database'
                  : widget.isImporting
                      ? 'Import in progress'
                      : null,
              child: TextButton.icon(
                onPressed: widget.clearDatabaseEnabled && positionCount > 0
                    ? widget.onClearDatabase
                    : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear Database'),
              ),
            ),
            _conditionalTooltip(
              message: positionCount == 0 ? 'No tactics to browse' : null,
              child: TextButton.icon(
                onPressed: positionCount > 0 ? widget.onBrowseTactics : null,
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('Browse Tactics'),
              ),
            ),
            if (positionCount > 0)
              TextButton.icon(
                onPressed: _showSessionSettingsDialog,
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Session Settings'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Wraps [child] in a [Tooltip] only when [message] is non-null.
///
/// Avoid empty tooltip messages — Flutter's OverlayPortal-based tooltips can
/// assert if the message toggles between empty and non-empty during hover.
Widget _conditionalTooltip({required String? message, required Widget child}) {
  final text = message?.trim();
  if (text == null || text.isEmpty) return child;
  return Tooltip(message: text, child: child);
}

/// Session settings form (order, mistake-type filter, 1-star toggle).
class _SessionSettingsForm extends StatelessWidget {
  const _SessionSettingsForm({
    required this.settings,
    required this.onChanged,
  });

  final TacticsSessionSettings settings;
  final ValueChanged<TacticsSessionSettings> onChanged;

  static const _orderLabels = {
    TacticsSessionOrder.newestFirst: 'Newest first',
    TacticsSessionOrder.leastReviewed: 'Least reviewed',
    TacticsSessionOrder.worstSuccessRate: 'Worst success rate',
    TacticsSessionOrder.random: 'Random',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('Order:',
                style: TextStyle(fontSize: 13, color: Colors.grey[300])),
            const SizedBox(width: 8),
            DropdownButton<TacticsSessionOrder>(
              value: settings.order,
              isDense: true,
              underline: const SizedBox(),
              style: const TextStyle(fontSize: 13),
              items: [
                for (final entry in _orderLabels.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(settings.copyWith(order: v));
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Include:',
            style: TextStyle(fontSize: 13, color: Colors.grey[300])),
        _MistakeTypeCheckbox(
          label: 'Blunders (??)',
          type: '??',
          selected: settings.mistakeTypes.contains('??'),
          onChanged: (v) => _toggleMistakeType('??', v),
        ),
        _MistakeTypeCheckbox(
          label: 'Mistakes (?)',
          type: '?',
          selected: settings.mistakeTypes.contains('?'),
          onChanged: (v) => _toggleMistakeType('?', v),
        ),
        _MistakeTypeCheckbox(
          label: 'Inaccuracies (?!)',
          type: '?!',
          selected: settings.mistakeTypes.contains('?!'),
          onChanged: (v) => _toggleMistakeType('?!', v),
        ),
        const SizedBox(height: 8),
        Text('Filter:',
            style: TextStyle(fontSize: 13, color: Colors.grey[300])),
        _MistakeTypeCheckbox(
          label: 'Unreviewed only',
          type: '',
          selected: settings.skipReviewed,
          onChanged: (v) => onChanged(settings.copyWith(skipReviewed: v)),
        ),
        _MistakeTypeCheckbox(
          label: '1-star rated',
          type: '',
          selected: settings.includeOneStar,
          onChanged: (v) => onChanged(settings.copyWith(includeOneStar: v)),
        ),
      ],
    );
  }

  void _toggleMistakeType(String type, bool include) {
    final types = Set<String>.from(settings.mistakeTypes);
    if (include) {
      types.add(type);
    } else {
      types.remove(type);
    }
    onChanged(settings.copyWith(mistakeTypes: types));
  }
}

class _MistakeTypeCheckbox extends StatelessWidget {
  const _MistakeTypeCheckbox({
    required this.label,
    required this.type,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final String type;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: selected,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

/// Progress/status banner shown during or after game import.
class TacticsImportStatusBanner extends StatelessWidget {
  const TacticsImportStatusBanner({
    super.key,
    required this.status,
    required this.isImporting,
    required this.hasActiveImport,
    required this.analyzedGameCount,
    required this.onCancelImport,
    required this.onDismiss,
  });

  final String status;
  final bool isImporting;
  final bool hasActiveImport;
  final int analyzedGameCount;
  final VoidCallback onCancelImport;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isImporting)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              if (isImporting) const SizedBox(width: 12),
              if (!isImporting)
                Icon(Icons.check_circle_outline,
                    size: 16, color: Colors.green[400]),
              if (!isImporting) const SizedBox(width: 8),
              Expanded(child: Text(status)),
              if (hasActiveImport)
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined, size: 20),
                  tooltip: 'Cancel analysis',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onCancelImport,
                ),
              if (!isImporting)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Dismiss',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onDismiss,
                ),
            ],
          ),
          if (analyzedGameCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              '$analyzedGameCount games already analyzed (will be skipped)',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        ],
      ),
    );
  }
}
