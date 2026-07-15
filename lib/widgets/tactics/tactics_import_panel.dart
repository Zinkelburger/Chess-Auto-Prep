import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../models/tactics_position.dart';
import '../../models/tactics_session_settings.dart';
import '../../services/tactics/tactics_import_coordinator.dart';
import '../../services/tactics_import_service.dart';

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

class _TacticsImportPanelState extends State<TacticsImportPanel> {
  var _settings = const TacticsSessionSettings();

  final _sinceDaysController = TextEditingController();
  final _sinceDaysFocus = FocusNode();

  int get _matchingCount => _settings.countMatching(widget.positions);

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
                showCustomType: _presentMistakeTypes.contains(
                  TacticsSessionSettings.customMistakeType,
                ),
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
                  draft.save();
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

  // ── Start card ─────────────────────────────────────────────────────────

  Widget _buildStartCard(int positionCount) {
    final matchingCount = _matchingCount;

    // A single helper line under the button; exactly one variant renders so
    // the card height stays stable.
    // Only shown when the user needs to act (or wait); no hint in the
    // ordinary ready state — the button's "(N ready)" already says it all.
    String? hint;
    Color hintColor = Colors.grey[400]!;
    if (positionCount == 0) {
      hint = 'No tactics yet — import your games above to get started.';
    } else if (matchingCount == 0) {
      hint =
          'All $positionCount positions are filtered out — '
          'loosen the filters.';
      hintColor = Colors.orange[300]!;
    } else if (widget.isImporting) {
      hint = 'Import is running — new tactics are added as they\'re found.';
      hintColor = Colors.green[400]!;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Practice', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildFilterSummaryRow(),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: matchingCount > 0
                    ? () => widget.onStartSession(_settings)
                    : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  'Start Practice Session ($matchingCount ready)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(hint, style: TextStyle(fontSize: 12, color: hintColor)),
            ],
          ],
        ),
      ),
    );
  }

  static String _recencyLabel(int? maxAgeDays) => switch (maxAgeDays) {
    null => 'All time',
    1 => 'Today',
    final d => 'Last $d days',
  };

  static const _mistakeTypeNames = {
    '??': 'Blunders',
    '?': 'Mistakes',
    '?!': 'Inaccuracies',
    TacticsSessionSettings.customMistakeType: 'Custom puzzles',
  };

  /// Mistake types that actually occur in the current database.
  Set<String> get _presentMistakeTypes => {
    for (final pos in widget.positions) pos.mistakeType,
  };

  String get _mistakeTypesLabel {
    // Only talk about types the database actually has — mentioning "Custom
    // puzzles" when there are none just confuses. With an empty database,
    // fall back to the standard three.
    final present = _presentMistakeTypes;
    final relevant = present.isEmpty
        ? (_mistakeTypeNames.keys.toSet()
            ..remove(TacticsSessionSettings.customMistakeType))
        : present;
    final selected = [
      for (final entry in _mistakeTypeNames.entries)
        if (relevant.contains(entry.key) &&
            _settings.mistakeTypes.contains(entry.key))
          entry.value,
    ];
    if (selected.isEmpty) return 'No mistake types selected';
    if (selected.length == relevant.length && relevant.length >= 3) {
      return 'All mistake types';
    }
    return selected.join(', ');
  }

  /// One plain-text summary of the active session filter plus a single,
  /// clearly-labeled button that opens the settings dialog.
  Widget _buildFilterSummaryRow() {
    final summary =
        '${_recencyLabel(_settings.maxAgeDays)} · $_mistakeTypesLabel';
    return Row(
      children: [
        Icon(Icons.filter_alt_outlined, size: 14, color: Colors.grey[500]),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            summary,
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: _showSessionSettingsDialog,
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('Filters…'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }

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

/// Wraps [child] in a [Tooltip] only when [message] is non-null.
///
/// Avoid empty tooltip messages — Flutter's OverlayPortal-based tooltips can
/// assert if the message toggles between empty and non-empty during hover.
Widget _conditionalTooltip({required String? message, required Widget child}) {
  final text = message?.trim();
  if (text == null || text.isEmpty) return child;
  return Tooltip(message: text, child: child);
}

/// A selectable row: tapping anywhere selects the mode. The active row gets a
/// primary-colored left border accent; the inactive row dims. (Andrew prefers
/// this fade look over radio buttons — don't "fix" it.)
class _FetchModeRow extends StatelessWidget {
  const _FetchModeRow({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: selected ? 1.0 : 0.40,
        duration: const Duration(milliseconds: 150),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          child: child,
        ),
      ),
    );
  }
}

/// Session settings form (recency window, order, mistake-type filter,
/// 1-star toggle).
class _SessionSettingsForm extends StatelessWidget {
  const _SessionSettingsForm({
    required this.settings,
    required this.showCustomType,
    required this.onChanged,
  });

  final TacticsSessionSettings settings;

  /// Whether the database contains any custom puzzles; the checkbox is
  /// hidden otherwise so the dialog only offers choices that exist.
  final bool showCustomType;

  final ValueChanged<TacticsSessionSettings> onChanged;

  static const _orderLabels = {
    TacticsSessionOrder.newestFirst: 'Newest first',
    TacticsSessionOrder.leastReviewed: 'Least reviewed',
    TacticsSessionOrder.worstSuccessRate: 'Worst success rate',
    TacticsSessionOrder.random: 'Random',
  };

  /// Recency presets: days back, or null for all time.
  static const _agePresets = <(int?, String)>[
    (1, 'Today'),
    (2, '2 days'),
    (7, '7 days'),
    (14, '14 days'),
    (null, 'All time'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'From games in the last:',
          style: TextStyle(fontSize: 13, color: Colors.grey[300]),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (days, label) in _agePresets)
              ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: settings.maxAgeDays == days,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => onChanged(
                  days == null
                      ? settings.copyWith(clearMaxAgeDays: true)
                      : settings.copyWith(maxAgeDays: days),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              'Order:',
              style: TextStyle(fontSize: 13, color: Colors.grey[300]),
            ),
            const SizedBox(width: 8),
            DropdownButton<TacticsSessionOrder>(
              value: settings.order,
              isDense: true,
              underline: const SizedBox(),
              style: const TextStyle(fontSize: 13),
              items: [
                for (final entry in _orderLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (v) {
                if (v != null) onChanged(settings.copyWith(order: v));
              },
            ),
          ],
        ),
        _MistakeTypeCheckbox(
          label: 'Group by game',
          selected: settings.groupByGame,
          onChanged: (v) => onChanged(settings.copyWith(groupByGame: v)),
        ),
        const SizedBox(height: 12),
        Text(
          'Mistake types to include:',
          style: TextStyle(fontSize: 13, color: Colors.grey[300]),
        ),
        _MistakeTypeCheckbox(
          label: 'Blunders (??)',
          selected: settings.mistakeTypes.contains('??'),
          onChanged: (v) => _toggleMistakeType('??', v),
        ),
        _MistakeTypeCheckbox(
          label: 'Mistakes (?)',
          selected: settings.mistakeTypes.contains('?'),
          onChanged: (v) => _toggleMistakeType('?', v),
        ),
        _MistakeTypeCheckbox(
          label: 'Inaccuracies (?!)',
          selected: settings.mistakeTypes.contains('?!'),
          onChanged: (v) => _toggleMistakeType('?!', v),
        ),
        if (showCustomType)
          _MistakeTypeCheckbox(
            label: 'Custom puzzles',
            selected: settings.mistakeTypes.contains(
              TacticsSessionSettings.customMistakeType,
            ),
            onChanged: (v) =>
                _toggleMistakeType(TacticsSessionSettings.customMistakeType, v),
          ),
        const SizedBox(height: 8),
        Text(
          'Options:',
          style: TextStyle(fontSize: 13, color: Colors.grey[300]),
        ),
        _MistakeTypeCheckbox(
          label: 'Unreviewed only',
          selected: settings.skipReviewed,
          onChanged: (v) => onChanged(settings.copyWith(skipReviewed: v)),
        ),
        _MistakeTypeCheckbox(
          label: 'Exclude 1-star rated',
          selected: !settings.includeOneStar,
          onChanged: (v) => onChanged(settings.copyWith(includeOneStar: !v)),
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
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => onChanged(!selected),
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
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offer to finish analyzing games that were fetched but never analyzed
/// (a stopped or interrupted import). Sits at the top and mirrors
/// [TacticsImportStatusBanner]'s look, so stopping an import and resuming
/// it live in the same place: stop button while running, run button after.
class _ResumeAnalysisBanner extends StatelessWidget {
  const _ResumeAnalysisBanner({
    required this.pendingGameCount,
    required this.onResume,
  });

  final int pendingGameCount;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue),
      ),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline, size: 16, color: Colors.blue[300]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$pendingGameCount recent game${pendingGameCount == 1 ? '' : 's'} '
              'fetched but not analyzed yet',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.play_circle_outlined, size: 20),
            tooltip: 'Resume analysis',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onResume,
          ),
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
    required this.onCancelImport,
    required this.onDismiss,
  });

  final String status;
  final bool isImporting;
  final bool hasActiveImport;
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (isImporting) const SizedBox(width: 12),
              if (!isImporting)
                Icon(
                  Icons.check_circle_outline,
                  size: 16,
                  color: Colors.green[400],
                ),
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
        ],
      ),
    );
  }
}
