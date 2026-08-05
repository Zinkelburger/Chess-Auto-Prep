// The accounts half of the tactics home's right pane. Part of
// tactics_import_panel.dart.
part of 'tactics_import_panel.dart';

mixin _TacticsImportPanelAccountsCard on _TacticsImportPanelStateBase {
  // ── My accounts (always visible) ────────────────────────────────────────

  /// Where the games come from, and which of them count as recent.
  ///
  /// This card used to be "Import Games", with an Import button per site and an
  /// engine-settings gear. Both are gone: downloading, checking against your
  /// books and finding your mistakes is one job now, started by the review's
  /// play button on the left, and the engine knobs are on that same strip where
  /// you can see them. What is left here is the two things this card is
  /// genuinely about — who you are, and which games count.
  ///
  /// Both usernames live here rather than at the head of the games pane: that
  /// pane already carries the rating, the counts, the books and the list, and
  /// an underline-styled box up there had no label saying what it was. Here
  /// each field has a title. (An earlier pass tried the games-pane header;
  /// the user sent them back.)
  Widget _buildAccountsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'My accounts',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 14),
              _AccountUsernameField(
                fieldKey: const Key('lichess-username-field'),
                label: 'Lichess Username',
                read: (s) => s.lichessUsername,
                write: (s, v) => s.setLichessUsername(v),
                lastFetch: (s) => s.lichessLastFetch,
              ),
              const SizedBox(height: 12),
              _AccountUsernameField(
                fieldKey: const Key('chesscom-username-field'),
                label: 'Chess.com Username',
                read: (s) => s.chesscomUsername,
                write: (s, v) => s.setChesscomUsername(v),
                lastFetch: (s) => s.chesscomLastFetch,
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              _buildWindowSection(),
            ],
          ),
        ),
      ),
    );
  }

  /// The shared games window (see `GamesWindowSettings`). The same value backs
  /// the recent-games list on the left of this screen, so the two halves can
  /// never disagree about which games "recent" means; whichever surface the
  /// user edits it in, both move.
  Widget _buildWindowSection() {
    final window = _form.window;
    final byGames = window.isGameCount;

    Color dimmed(bool active) =>
        active ? AppColors.onSurfaceSoft : AppColors.onSurfaceDisabled;

    // The two window modes sit side by side on one line, both phrased the
    // same way ("Last [N] games" / "Last [N] days") so no separator word
    // is needed. Each stays a tappable _FetchModeRow so the fade/left-accent
    // selection look is preserved.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Says what pressing the analysis button will fetch, rather than
        // defining a word ("recent") the user never asked about.
        const Text(
          'Games to download',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: _FetchModeRow(
                selected: byGames,
                onTap: () => _form.setWindowMode(GamesWindowMode.lastGames),
                child: Row(
                  children: [
                    Text(
                      'Last',
                      style: TextStyle(fontSize: 13, color: dimmed(byGames)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      child: TextField(
                        // Keyed: the field has no label to find it by, and the
                        // e2e review test has to type a game count into it.
                        key: const Key('window-games-field'),
                        controller: _form.gamesText,
                        focusNode: _gamesFocus,
                        enabled: byGames,
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
                          final games = int.tryParse(value);
                          if (games != null && games > 0) {
                            _form.setWindowGames(games);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'games',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: dimmed(byGames)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FetchModeRow(
                selected: !byGames,
                onTap: () => _form.setWindowMode(GamesWindowMode.lastDays),
                child: Row(
                  children: [
                    Text(
                      'Last',
                      style: TextStyle(fontSize: 13, color: dimmed(!byGames)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      child: TextField(
                        controller: _form.daysText,
                        focusNode: _daysFocus,
                        enabled: !byGames,
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
                            _form.setWindowDays(days);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'days',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: dimmed(!byGames)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One account: a labelled username box, and — only once there *is* a name —
/// when its games were last pulled down. An empty field has no download
/// history to report, and "Not downloaded yet" under a blank box reads as a
/// problem to fix rather than as the absence of an account.
///
/// The value of record is [AppState]'s (persisted per keystroke as the saved
/// default; Settings → Accounts edits the same value). Edits made elsewhere
/// are adopted here — but never while this field has focus, or the caret
/// jumps.
class _AccountUsernameField extends StatefulWidget {
  const _AccountUsernameField({
    required this.fieldKey,
    required this.label,
    required this.read,
    required this.write,
    required this.lastFetch,
  });

  /// Keyed for the boot integration test, which types a username into the
  /// field to drive a download.
  final Key fieldKey;
  final String label;
  final String? Function(AppState state) read;
  final void Function(AppState state, String value) write;
  final DateTime? Function(AppState state) lastFetch;

  @override
  State<_AccountUsernameField> createState() => _AccountUsernameFieldState();
}

class _AccountUsernameFieldState extends State<_AccountUsernameField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  AppState? _appState;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = context.read<AppState>();
    if (!identical(appState, _appState)) {
      _appState?.removeListener(_onAppStateChanged);
      _appState = appState;
      appState.addListener(_onAppStateChanged);
      _syncFromAppState();
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Every write goes through [AppState] (including this field's own
  /// onChanged), so one listener covers both the name and the
  /// last-downloaded line.
  void _onAppStateChanged() {
    _syncFromAppState();
    if (mounted) setState(() {});
  }

  void _syncFromAppState() {
    final appState = _appState;
    if (appState == null) return;
    final name = widget.read(appState) ?? '';
    if (!_focus.hasFocus && _controller.text != name) {
      _controller.text = name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    final lastSynced = widget.lastFetch(appState);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: widget.fieldKey,
          controller: _controller,
          focusNode: _focus,
          decoration: InputDecoration(
            labelText: widget.label,
            // Pinned small on the border, never full-size inside the box: an
            // empty field that says "Lichess Username" in body type reads as
            // a filled-in value, not as the field's title.
            floatingLabelBehavior: FloatingLabelBehavior.always,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => widget.write(appState, v),
        ),
        if (_controller.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              lastSynced != null
                  ? 'Last downloaded ${_formatDate(lastSynced)}'
                  : 'Not downloaded yet',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
      ],
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
