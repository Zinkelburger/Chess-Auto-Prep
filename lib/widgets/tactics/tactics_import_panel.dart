import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../services/tactics_import_service.dart';

/// Import controls and session start UI when no tactic is active.
class TacticsImportPanel extends StatelessWidget {
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
    required this.positionCount,
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
  final int positionCount;
  final VoidCallback onStartSession;
  final VoidCallback onClearDatabase;
  final VoidCallback onBrowseTactics;
  final bool clearDatabaseEnabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (importStatus != null) ...[
          TacticsImportStatusBanner(
            status: importStatus!,
            isImporting: isImporting,
            hasActiveImport: activeImport != null,
            analyzedGameCount: analyzedGameCount,
            onCancelImport: onCancelImport,
            onDismiss: onDismissImportStatus,
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
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: lichessUserController,
                              decoration: const InputDecoration(
                                labelText: 'Lichess Username',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (value) {
                                context
                                    .read<AppState>()
                                    .setLichessUsername(value);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: lichessCountController,
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
                            onPressed: importStatus == null && importFieldsValid
                                ? onImportLichess
                                : null,
                            child: const Text('Import'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: chessComUserController,
                              decoration: const InputDecoration(
                                labelText: 'Chess.com Username',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (value) {
                                context
                                    .read<AppState>()
                                    .setChesscomUsername(value);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: chessComCountController,
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
                            onPressed: importStatus == null && importFieldsValid
                                ? onImportChessCom
                                : null,
                            child: const Text('Import'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox(
                            width: 140,
                            child: TextField(
                              controller: stockfishDepthController,
                              decoration: InputDecoration(
                                labelText: 'Stockfish Depth',
                                border: const OutlineInputBorder(),
                                isDense: true,
                                errorText: depthError,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: onValidateDepth,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 100,
                            child: TextField(
                              controller: coresController,
                              enabled:
                                  TacticsImportService.isParallelAvailable,
                              decoration: InputDecoration(
                                labelText: 'Cores',
                                border: const OutlineInputBorder(),
                                isDense: true,
                                errorText: coresError,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: onValidateCores,
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
        if (positionCount > 0)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onStartSession,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
                backgroundColor: isImporting
                    ? Colors.green[700]
                    : Theme.of(context).colorScheme.primaryContainer,
              ),
              icon: Icon(isImporting ? Icons.play_circle : Icons.play_arrow),
              label: Text(
                isImporting
                    ? 'Start Training Now ($positionCount positions)'
                    : 'Start Practice Session ($positionCount positions)',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        if (isImporting && positionCount > 0) ...[
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
            Tooltip(
              message: positionCount == 0
                  ? 'No positions in database'
                  : isImporting
                      ? 'Import in progress'
                      : '',
              child: TextButton.icon(
                onPressed: clearDatabaseEnabled && positionCount > 0
                    ? onClearDatabase
                    : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear Database'),
              ),
            ),
            const SizedBox(width: 16),
            Tooltip(
              message: positionCount == 0 ? 'No tactics to browse' : '',
              child: TextButton.icon(
                onPressed:
                    positionCount > 0 ? onBrowseTactics : null,
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('Browse Tactics'),
              ),
            ),
          ],
        ),
      ],
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
