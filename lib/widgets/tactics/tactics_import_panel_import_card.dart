part of 'tactics_import_panel.dart';

mixin _TacticsImportPanelImportCard on _TacticsImportPanelStateBase {
  // ── Import Games (always visible) ──────────────────────────────────────

  Widget _buildImportCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Import Games',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    tooltip: 'Engine settings…',
                    visualDensity: VisualDensity.compact,
                    onPressed: _showEngineSettingsDialog,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Fetch your games and turn your mistakes into puzzles.',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
              const SizedBox(height: 14),
              _buildImportSourceRow(
                userController: widget.lichessUserController,
                userLabel: 'Lichess Username',
                onUsernameChanged: (v) =>
                    context.read<AppState>().setLichessUsername(v),
                onImport: widget.onImportLichess,
              ),
              const SizedBox(height: 12),
              _buildImportSourceRow(
                userController: widget.chessComUserController,
                userLabel: 'Chess.com Username',
                onUsernameChanged: (v) =>
                    context.read<AppState>().setChesscomUsername(v),
                onImport: widget.onImportChessCom,
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              _buildFetchModeSection(),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              _buildAutoFetchSection(),
            ],
          ),
        ),
      ),
    );
  }

  /// A single import-source row: username field and an Import button
  /// (enabled only when no import is in progress and fields are valid).
  Widget _buildImportSourceRow({
    required TextEditingController userController,
    required String userLabel,
    required ValueChanged<String> onUsernameChanged,
    required VoidCallback onImport,
  }) {
    // Enablement mirrors the real preconditions the import action checks:
    // a username is required, fields must be valid, and no import may
    // already be running. A leftover status banner is purely informational
    // and must NOT block a new import.
    final hasUsername = userController.text.trim().isNotEmpty;
    final canImport =
        hasUsername && widget.importFieldsValid && !widget.isImporting;

    String? disabledReason;
    if (!canImport) {
      if (widget.isImporting) {
        disabledReason = 'Import already in progress';
      } else if (!hasUsername) {
        disabledReason = 'Enter a username first';
      } else {
        disabledReason = 'Fix the engine settings (gear icon above)';
      }
    }

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
        _conditionalTooltip(
          message: disabledReason,
          child: ElevatedButton(
            onPressed: canImport ? onImport : null,
            child: const Text('Import'),
          ),
        ),
      ],
    );
  }

  Widget _buildFetchModeSection() {
    final isRecent = widget.fetchMode == TacticsImportMode.recent;
    final isSince = !isRecent;

    Color dimmed(bool active) => active ? Colors.grey[400]! : Colors.grey[700]!;

    // The two fetch modes sit side by side on one line, both phrased the
    // same way ("Last [N] days" / "Latest [N] games") so no separator word
    // is needed. Each stays a tappable _FetchModeRow so the fade/left-accent
    // selection look is preserved.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: _FetchModeRow(
            selected: isSince,
            onTap: () => widget.onFetchModeChanged(TacticsImportMode.sinceDate),
            child: Row(
              children: [
                Text(
                  'Last',
                  style: TextStyle(fontSize: 13, color: dimmed(isSince)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 52,
                  child: TextField(
                    controller: _sinceDaysController,
                    focusNode: _sinceDaysFocus,
                    enabled: isSince,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      final days = int.tryParse(value);
                      if (days != null && days > 0) {
                        widget.onSinceDaysChanged(days);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'days',
                  style: TextStyle(fontSize: 13, color: dimmed(isSince)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _FetchModeRow(
            selected: isRecent,
            onTap: () => widget.onFetchModeChanged(TacticsImportMode.recent),
            child: Row(
              children: [
                Text(
                  'Latest',
                  style: TextStyle(fontSize: 13, color: dimmed(isRecent)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 52,
                  child: TextField(
                    controller: widget.lichessCountController,
                    enabled: isRecent,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'games',
                  style: TextStyle(fontSize: 13, color: dimmed(isRecent)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAutoFetchSection() {
    final appState = context.read<AppState>();

    String syncedLabel(String source, DateTime? last) =>
        '$source: ${last != null ? 'last synced ${_formatDate(last)}' : 'never synced'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () =>
                    appState.setTacticsAutoFetch(!appState.tacticsAutoFetch),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: appState.tacticsAutoFetch,
                          onChanged: (v) =>
                              appState.setTacticsAutoFetch(v ?? false),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Flexible(
                        child: Text(
                          'Auto-fetch on startup',
                          style: TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _conditionalTooltip(
              message: widget.isImporting ? 'Import in progress' : null,
              child: TextButton.icon(
                onPressed: widget.isImporting ? null : widget.onFetchNew,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Re-fetch'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                syncedLabel('Lichess', appState.lichessLastFetch),
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
              Text(
                syncedLabel('Chess.com', appState.chesscomLastFetch),
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Engine tuning for import analysis — per-machine knobs most users never
  /// touch, so they live behind the gear icon instead of on the main page.
  ///
  /// Validation state (`depthError`/`coresError`) lives in the parent; the
  /// `setDialogState` after each validator call re-reads it once the parent
  /// has rebuilt this panel with the new error props.
  Future<void> _showEngineSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Engine Settings'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Used when analyzing imported games. Higher depth finds '
                  'better lines but is slower.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: widget.stockfishDepthController,
                  decoration: InputDecoration(
                    labelText: 'Stockfish depth',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: widget.depthError,
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    widget.onValidateDepth(v);
                    setDialogState(() {});
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: widget.coresController,
                  enabled: TacticsImportService.isParallelAvailable,
                  decoration: InputDecoration(
                    labelText: 'CPU cores',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: widget.coresError,
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    widget.onValidateCores(v);
                    setDialogState(() {});
                  },
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
