import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../models/tactics_position.dart';
import '../../models/tactics_session_settings.dart';
import '../../services/tactics/tactics_import_coordinator.dart';
import '../../services/tactics_import_service.dart';
import '../../theme/app_colors.dart';

part 'tactics_import_panel_start_card.dart';
part 'tactics_import_panel_import_card.dart';
part 'tactics_import_panel_widgets.dart';

/// Tactics home screen when no puzzle is active: an always-visible Import
/// Games card (usernames front and center, engine knobs behind a gear
/// dialog), then the Practice card with the start button at the bottom.
///
/// Layout rule: the structure is static. Sections never collapse, reorder,
/// or appear/disappear in reaction to typing — only transient status
/// (import progress, resume-analysis) may come and go.
class TacticsImportPanel extends StatefulWidget {
  const TacticsImportPanel({
    super.key,
    this.importStatus,
    required this.isImporting,
    this.isCancelling = false,
    this.activeImport,
    required this.lichessUserController,
    required this.lichessCountController,
    required this.chessComUserController,
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
    required this.fetchMode,
    required this.onFetchModeChanged,
    required this.sinceDays,
    required this.onSinceDaysChanged,
    this.pendingGameCount = 0,
    this.totalStoredGames = 0,
    this.onResumeAnalysis,
    this.onFetchNew,
  });

  final String? importStatus;
  final bool isImporting;
  final bool isCancelling;
  final TacticsImportService? activeImport;
  final TextEditingController lichessUserController;
  final TextEditingController lichessCountController;
  final TextEditingController chessComUserController;
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
  final TacticsImportMode fetchMode;
  final ValueChanged<TacticsImportMode> onFetchModeChanged;
  final int sinceDays;
  final ValueChanged<int> onSinceDaysChanged;
  final int pendingGameCount;
  final int totalStoredGames;
  final VoidCallback? onResumeAnalysis;

  /// Fetch new games from every configured source (the sync-row refresh).
  final VoidCallback? onFetchNew;

  @override
  State<TacticsImportPanel> createState() => _TacticsImportPanelState();
}

/// Shared state for [TacticsImportPanel]: the fields the card mixins read and
/// mutate. The concrete [_TacticsImportPanelState] applies the card mixins and
/// keeps the lifecycle hooks and [build].
abstract class _TacticsImportPanelStateBase extends State<TacticsImportPanel> {
  var _settings = const TacticsSessionSettings();

  final _sinceDaysController = TextEditingController();
  final _sinceDaysFocus = FocusNode();
}

class _TacticsImportPanelState extends _TacticsImportPanelStateBase
    with _TacticsImportPanelStartCard, _TacticsImportPanelImportCard {
  @override
  void initState() {
    super.initState();
    // The Import buttons enable/disable based on whether a username is
    // present, so rebuild as the user types. (Controllers are owned by the
    // parent; we only add/remove listeners here, never dispose them.)
    widget.lichessUserController.addListener(_onUsernameChanged);
    widget.chessComUserController.addListener(_onUsernameChanged);
    _sinceDaysController.text = '${widget.sinceDays}';
    // Restore the user's last-used session settings.
    TacticsSessionSettings.load().then((saved) {
      if (mounted) setState(() => _settings = saved);
    });
  }

  @override
  void didUpdateWidget(TacticsImportPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect externally restored prefs into the days field, but never fight
    // the user while they're typing in it.
    if (!_sinceDaysFocus.hasFocus &&
        int.tryParse(_sinceDaysController.text) != widget.sinceDays) {
      _sinceDaysController.text = '${widget.sinceDays}';
    }
  }

  @override
  void dispose() {
    widget.lichessUserController.removeListener(_onUsernameChanged);
    widget.chessComUserController.removeListener(_onUsernameChanged);
    _sinceDaysController.dispose();
    _sinceDaysFocus.dispose();
    super.dispose();
  }

  void _onUsernameChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final positionCount = widget.positions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.importStatus != null) ...[
          TacticsImportStatusBanner(
            status: widget.importStatus!,
            isImporting: widget.isImporting,
            hasActiveImport: widget.activeImport != null,
            isCancelling: widget.isCancelling,
            onCancelImport: widget.onCancelImport,
            onDismiss: widget.onDismissImportStatus,
          ),
          const SizedBox(height: 16),
        ],
        if (widget.pendingGameCount > 0 && !widget.isImporting) ...[
          _ResumeAnalysisBanner(
            pendingGameCount: widget.pendingGameCount,
            onResume: widget.onResumeAnalysis,
          ),
          const SizedBox(height: 16),
        ],
        _buildImportCard(),
        const SizedBox(height: 12),
        _buildStartCard(positionCount),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            _conditionalTooltip(
              message: positionCount == 0 ? 'No tactics to browse' : null,
              child: TextButton.icon(
                onPressed: positionCount > 0 ? widget.onBrowseTactics : null,
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('Browse Tactics'),
              ),
            ),
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
          ],
        ),
      ],
    );
  }
}
