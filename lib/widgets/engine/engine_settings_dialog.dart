/// Engine analysis settings dialog extracted from [UnifiedEnginePane].
///
/// Shows toggle switches for analysis sources (Stockfish, Maia, Ease,
/// Probability) and numeric controls for engine parameters.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/engine_settings.dart';
import '../../services/lichess_auth_service.dart';
import '../../utils/chess_utils.dart' show formatRam;

/// Show the engine settings dialog.
///
/// [settings] is the singleton [EngineSettings] instance.
/// [onSettingsChanged] fires after the dialog closes (or after the
/// probability starting-moves field is committed) so the parent can
/// invalidate the analysis cache and restart.
/// [currentProbabilityStartMoves] seeds the text field.
/// [onProbabilityStartMovesChanged] fires when the field value changes.
void showEngineSettingsDialog({
  required BuildContext context,
  required EngineSettings settings,
  required String currentProbabilityStartMoves,
  required ValueChanged<String> onProbabilityStartMovesChanged,
}) {
  final probController =
      TextEditingController(text: currentProbabilityStartMoves);

  // Lichess OAuth flow state, scoped to this dialog instance.
  String? oauthUrl;
  bool oauthWaiting = false;

  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final lichess = LichessAuthService();

        return AlertDialog(
          title: const Text('Analysis Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Lichess Account ──
                _buildLichessSection(
                  context: context,
                  lichess: lichess,
                  oauthUrl: oauthUrl,
                  oauthWaiting: oauthWaiting,
                  onStartOAuth: () async {
                    final url = await lichess.startOAuthFlow();
                    setDialogState(() {
                      oauthUrl = url;
                      oauthWaiting = true;
                    });
                    // Open in browser automatically
                    LichessAuthService.openUrl(url);
                    // Wait for the callback in background
                    final success = await lichess.waitForCallback();
                    setDialogState(() {
                      oauthWaiting = false;
                      if (success) oauthUrl = null;
                    });
                  },
                  onLogout: () async {
                    await lichess.logout();
                    setDialogState(() {
                      oauthUrl = null;
                      oauthWaiting = false;
                    });
                  },
                ),

                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),

                // ── Sources ──
                Text('Sources',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[400])),
                _buildToggleTile('Stockfish', settings.showStockfish, (v) {
                  settings.showStockfish = v;
                  setDialogState(() {});
                }),
                _buildToggleTile('Maia', settings.showMaia, (v) {
                  settings.showMaia = v;
                  setDialogState(() {});
                }),
                _buildToggleTile('Ease', settings.showEase, (v) {
                  settings.showEase = v;
                  setDialogState(() {});
                }),
                _buildToggleTile('Probability', settings.showProbability,
                    (v) {
                  settings.showProbability = v;
                  setDialogState(() {});
                }),

                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),

                // ── Stockfish Engine ──
                Text('Stockfish Engine',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[400])),
                const SizedBox(height: 4),
                Text(
                  'System: ${EngineSettings.systemCores} cores, '
                  '${formatRam(EngineSettings.systemRamMb)} RAM',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 8),
                _buildNumberField(
                  label: 'Max System Load (%)',
                  value: settings.maxSystemLoad,
                  min: 50,
                  max: 100,
                  step: 5,
                  onChanged: (v) {
                    settings.maxSystemLoad = v;
                    setDialogState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    'Up to ${settings.cores} workers, '
                    '${formatRam(settings.hashMb)} hash budget '
                    '(${settings.hashPerWorker} MB/worker)',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic),
                  ),
                ),
                _buildNumberField(
                  label: 'Eval Depth',
                  value: settings.depth,
                  min: 1,
                  max: 99,
                  onChanged: (v) {
                    settings.depth = v;
                    setDialogState(() {});
                  },
                ),
                _buildNumberField(
                  label: 'Ease Depth',
                  value: settings.easeDepth,
                  min: 1,
                  max: 99,
                  onChanged: (v) {
                    settings.easeDepth = v;
                    setDialogState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    'Lower = faster ease (runs per Maia candidate)',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic),
                  ),
                ),
                _buildNumberField(
                  label: 'MultiPV (Lines)',
                  value: settings.multiPv,
                  min: 1,
                  max: 10,
                  onChanged: (v) {
                    settings.multiPv = v;
                    setDialogState(() {});
                  },
                ),
                _buildNumberField(
                  label: 'Max Moves',
                  value: settings.maxAnalysisMoves,
                  min: 3,
                  max: 20,
                  onChanged: (v) {
                    settings.maxAnalysisMoves = v;
                    setDialogState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    'MultiPV lines + top Maia/DB candidates '
                    '(${settings.maxAnalysisMoves - settings.multiPv} '
                    'extra slots)',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic),
                  ),
                ),

                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),

                // ── Maia ──
                Text('Maia',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[400])),
                const SizedBox(height: 4),
                _buildNumberField(
                  label: 'Maia Elo',
                  value: settings.maiaElo,
                  min: 1100,
                  max: 2100,
                  step: 100,
                  onChanged: (v) {
                    settings.maiaElo = v;
                    setDialogState(() {});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    'Human-like move prediction strength (DB fallback)',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic),
                  ),
                ),

                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),

                // ── Probability ──
                Text('Probability',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[400])),
                const SizedBox(height: 8),
                Text(
                  'Starting Moves',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey[300]),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: probController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'e.g., 1. d4 d5 2. c4',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                  ),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 13),
                  maxLines: 2,
                ),
                const SizedBox(height: 4),
                Text(
                  'Leave empty for initial position',
                  style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 11,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                final newStartMoves = probController.text;
                if (newStartMoves != currentProbabilityStartMoves) {
                  onProbabilityStartMovesChanged(newStartMoves);
                }
                Navigator.pop(context);
              },
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

// ── Private helpers ──────────────────────────────────────────────────────

/// Lichess login / status section shown at the top of the dialog.
Widget _buildLichessSection({
  required BuildContext context,
  required LichessAuthService lichess,
  required String? oauthUrl,
  required bool oauthWaiting,
  required VoidCallback onStartOAuth,
  required VoidCallback onLogout,
}) {
  // ── Logged-in state ──
  if (lichess.isLoggedIn) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 18, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Logged in as ${lichess.username ?? 'Lichess user'}'
              '${lichess.isPat ? ' (PAT)' : ''}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onLogout,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Logout', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── OAuth URL has been generated — show link + copy button ──
  if (oauthUrl != null) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (oauthWaiting) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  oauthWaiting
                      ? 'Waiting for authorization...'
                      : 'Authorization failed — try again.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: oauthWaiting ? Colors.blue[300] : Colors.red[300],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Click the link below or copy it into your browser:',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 6),

          // Clickable link
          InkWell(
            onTap: () => LichessAuthService.openUrl(oauthUrl!),
            child: Text(
              oauthUrl!,
              style: TextStyle(
                fontSize: 11,
                color: Colors.blue[400],
                decoration: TextDecoration.underline,
                decorationColor: Colors.blue[400],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),

          // Copy button
          SizedBox(
            height: 30,
            child: OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: oauthUrl!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Link copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 14),
              label: const Text('Copy link', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Default: sign-in prompt ──
  return InkWell(
    onTap: onStartOAuth,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.login, size: 18, color: Colors.grey[400]),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Log into Lichess',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  'Faster database queries',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey[600]),
        ],
      ),
    ),
  );
}

Widget _buildToggleTile(
    String label, bool value, ValueChanged<bool> onChanged) {
  return SwitchListTile(
    title: Text(label),
    value: value,
    onChanged: onChanged,
    contentPadding: EdgeInsets.zero,
    dense: true,
  );
}

Widget _buildNumberField({
  required String label,
  required int value,
  required int min,
  required int max,
  int step = 1,
  required ValueChanged<int> onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13))),
        IconButton(
          icon: const Icon(Icons.remove, size: 18),
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
          padding: EdgeInsets.zero,
          constraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        SizedBox(
          width: 50,
          child: Text(
            value.toString(),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 18),
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
          padding: EdgeInsets.zero,
          constraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    ),
  );
}
