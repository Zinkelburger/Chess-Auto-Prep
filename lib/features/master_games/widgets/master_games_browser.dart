/// Browsing the local TWIC corpus, and seeing it against your own books.
///
/// Two million master games have been sitting on disk since the first sync,
/// readable only by the generator.  This is the window onto them: filter by
/// player, opening, event, strength or issue; or switch to **In my repertoire**
/// and be told which of those games walked into a line you play and what they
/// did when they got there.
///
/// Playing through them is not reimplemented here.  Any selection is written
/// out as an ordinary PGN collection and handed to the Games viewer, which
/// already has the board, the engine, the move tree and the study tools — and
/// leaves the user with a file they can open anywhere else too.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_state.dart';
import '../../../services/master_games/game_authority.dart';
import '../../../services/master_games/master_games_db.dart';
import '../../../services/master_games/master_games_query.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/open_in_file_manager.dart';
import '../controllers/master_games_browser_controller.dart';
import '../services/twic_repertoire_scan.dart';
import '../../../widgets/copy_button.dart';

/// Opens the browser over the current screen.
Future<void> showMasterGamesBrowser(
  BuildContext context, {
  required AppState appState,
  MasterGamesBrowserController? controller,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => MasterGamesBrowser(
      appState: appState,
      controller: controller ?? MasterGamesBrowserController(),
    ),
  );
}

class MasterGamesBrowser extends StatefulWidget {
  const MasterGamesBrowser({
    super.key,
    required this.appState,
    required this.controller,
  });

  final AppState appState;
  final MasterGamesBrowserController controller;

  @override
  State<MasterGamesBrowser> createState() => _MasterGamesBrowserState();
}

class _MasterGamesBrowserState extends State<MasterGamesBrowser> {
  final _player = TextEditingController();
  final _opponent = TextEditingController();
  final _event = TextEditingController();
  final _eco = TextEditingController();
  final _minElo = TextEditingController();

  MasterGamesBrowserController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
    unawaited(_c.search());
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _player.dispose();
    _opponent.dispose();
    _event.dispose();
    _eco.dispose();
    _minElo.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _applyFilters() async {
    await _c.setQuery(
      _c.query.copyWith(
        player: _player.text,
        opponent: _opponent.text,
        event: _event.text,
        eco: _eco.text,
        minElo: int.tryParse(_minElo.text),
        clearPlayer: _player.text.trim().isEmpty,
        clearOpponent: _opponent.text.trim().isEmpty,
        clearEvent: _event.text.trim().isEmpty,
        clearEco: _eco.text.trim().isEmpty,
        clearMinElo: _minElo.text.trim().isEmpty,
      ),
    );
  }

  Future<void> _openInViewer({MasterGame? focus}) async {
    final games = _c.visibleGames;
    if (games.isEmpty) return;
    final label = _collectionLabel();
    final path = await _c.writeCollection(label: label);
    if (!mounted) return;
    Navigator.pop(context);
    widget.appState.switchToPgnViewer(
      path: path,
      gameIndex: focus == null ? 0 : _c.indexOf(focus),
      historyLabel: 'Master games: $label',
    );
  }

  String _collectionLabel() {
    if (_c.mode == MasterBrowseMode.myRepertoire) {
      return 'twic-in-my-repertoire';
    }
    final parts = [
      if (_player.text.trim().isNotEmpty) _player.text.trim(),
      if (_opponent.text.trim().isNotEmpty) _opponent.text.trim(),
      if (_eco.text.trim().isNotEmpty) _eco.text.trim(),
      if (_event.text.trim().isNotEmpty) _event.text.trim(),
    ];
    return parts.isEmpty ? 'twic-games' : 'twic-${parts.join('-')}';
  }

  Future<void> _exportPgn() async {
    final games = _c.visibleGames;
    if (games.isEmpty) return;
    final path = await _c.writeCollection(label: _collectionLabel());
    if (!mounted) return;
    final opened = await openInFileManager(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? 'Saved ${games.length} games to $path'
              : 'Saved ${games.length} games — $path',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 860),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1),
            _filterBar(),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _list()),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 360, child: _details()),
                ],
              ),
            ),
            const Divider(height: 1),
            _footer(),
          ],
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _header() {
    final stats = _c.stats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          // Expanded rather than a Spacer: the coverage line is long enough
          // to push the mode buttons off a narrow window otherwise.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Master games', style: AppTextStyles.title),
                const SizedBox(height: 2),
                Text(
                  stats == null || stats.isEmpty
                      ? 'No games imported yet — sync The Week in Chess in '
                            'settings first.'
                      : '${_thousands(stats.games)} games from TWIC issues '
                            '${stats.firstIssue}–${stats.lastIssue}',
                  style: AppTextStyles.muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<MasterBrowseMode>(
            segments: const [
              ButtonSegment(
                value: MasterBrowseMode.all,
                label: Text('All games'),
              ),
              ButtonSegment(
                value: MasterBrowseMode.myRepertoire,
                label: Text('In my repertoire'),
              ),
            ],
            selected: {_c.mode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => unawaited(_c.setMode(s.first)),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  // ── Filters ─────────────────────────────────────────────────────────────

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _field(_player, 'Player', 150),
          _field(_opponent, 'Opponent', 150),
          _field(_eco, 'ECO', 70),
          _field(_event, 'Event', 160),
          _field(_minElo, 'Min Elo', 90, numeric: true),
          _authorityChip(),
          _orderButton(),
          FilledButton(
            onPressed: () => unawaited(_applyFilters()),
            child: const Text('Search'),
          ),
          if (!_c.query.isUnfiltered)
            TextButton(
              onPressed: () {
                _player.clear();
                _opponent.clear();
                _event.clear();
                _eco.clear();
                _minElo.clear();
                unawaited(
                  _c.setQuery(
                    const MasterGamesQuery(
                      limit: MasterGamesBrowserController.pageSize,
                    ),
                  ),
                );
              },
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    double width, {
    bool numeric = false,
  }) {
    return SizedBox(
      width: width,
      height: 38,
      child: TextField(
        controller: controller,
        style: AppTextStyles.body,
        keyboardType: numeric ? TextInputType.number : null,
        inputFormatters: numeric
            ? [FilteringTextInputFormatter.digitsOnly]
            : null,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 10,
          ),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => unawaited(_applyFilters()),
      ),
    );
  }

  /// Over half of TWIC is online blitz, so "classical over the board only" is
  /// the single most useful filter in the corpus.
  Widget _authorityChip() {
    final classicalOnly =
        _c.query.authorities.length == 1 &&
        _c.query.authorities.contains(GameAuthority.classical);
    return FilterChip(
      label: const Text('Classical OTB only'),
      selected: classicalOnly,
      onSelected: (on) => unawaited(
        _c.setQuery(
          _c.query.copyWith(
            authorities: on ? {GameAuthority.classical} : <GameAuthority>{},
          ),
        ),
      ),
    );
  }

  Widget _orderButton() {
    return SegmentedButton<MasterGamesOrder>(
      segments: const [
        ButtonSegment(value: MasterGamesOrder.newest, label: Text('Newest')),
        ButtonSegment(
          value: MasterGamesOrder.strongest,
          label: Text('Strongest'),
        ),
      ],
      selected: {_c.query.order},
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelectionChanged: (s) =>
          unawaited(_c.setQuery(_c.query.copyWith(order: s.first))),
    );
  }

  // ── List ────────────────────────────────────────────────────────────────

  Widget _list() {
    final error = _c.error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, style: AppTextStyles.body),
        ),
      );
    }
    if (_c.mode == MasterBrowseMode.myRepertoire) return _repertoireList();

    final games = _c.results;
    if (_c.isLoading && games.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (games.isEmpty) {
      return const Center(
        child: Text(
          'No games match these filters.',
          style: AppTextStyles.muted,
        ),
      );
    }
    return ListView.builder(
      itemCount: games.length + (_c.canLoadMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == games.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: OutlinedButton(
                onPressed: _c.isLoading ? null : () => unawaited(_c.loadMore()),
                child: Text(
                  _c.isLoading
                      ? 'Loading…'
                      : 'Load ${_thousands(_c.totalCount - games.length)} more',
                ),
              ),
            ),
          );
        }
        return _gameRow(games[i], i);
      },
    );
  }

  Widget _repertoireList() {
    if (_c.isScanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 240,
              child: LinearProgressIndicator(
                value: _c.scanTotal == 0
                    ? null
                    : _c.scanDone / _c.scanTotal.clamp(1, 1 << 30),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Checking ${_thousands(_c.scanDone)} of '
              '${_thousands(_c.scanTotal)} games against your books…',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: _c.cancelScan, child: const Text('Stop')),
          ],
        ),
      );
    }

    final scan = _c.scanResult;
    if (scan == null) {
      return Center(
        child: OutlinedButton(
          onPressed: () => unawaited(_c.runScan()),
          child: const Text('Check these games against my books'),
        ),
      );
    }
    if (!scan.hasAnyBook || scan.matches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                scan.headline,
                textAlign: TextAlign.center,
                style: AppTextStyles.body,
              ),
              if (!scan.hasAnyBook) ...[
                const SizedBox(height: 8),
                const Text(
                  'Designate one on the home page, under your repertoires.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.muted,
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          color: AppColors.surfaceElevated,
          child: Text(scan.headline, style: AppTextStyles.body),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: scan.matches.length,
            itemBuilder: (context, i) =>
                _gameRow(scan.matches[i].game, i, match: scan.matches[i]),
          ),
        ),
      ],
    );
  }

  Widget _gameRow(MasterGame game, int index, {TwicMatch? match}) {
    final selected = _c.selected?.id == game.id;
    // Selecting on the raw pointer-down rather than through the gesture
    // arena: a double-tap handler makes every tap — `onTap` and `onTapDown`
    // alike — wait out the ~300 ms double-tap window before firing, and a
    // third of a second of lag on every row makes the list feel broken.
    // Double-click still opens the game; `onTap` stays for the ink and for
    // keyboard/assistive activation.
    return Listener(
      onPointerDown: (_) => _c.select(game),
      child: InkWell(
        onTap: () => _c.select(game),
        onDoubleTap: () => unawaited(_openInViewer(focus: game)),
        child: Container(
          color: selected
              ? AppColors.surfaceContainer
              : (index.isEven ? AppColors.rowStripe : null),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_name(game.white)} – ${_name(game.black)}',
                      style: AppTextStyles.bodyStrong,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_eloPair(game), style: AppTextStyles.muted),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 44,
                    child: Text(game.result, style: AppTextStyles.body),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (game.eco.isNotEmpty) game.eco,
                  if (game.event.isNotEmpty) game.event,
                  if (game.date.isNotEmpty) game.date.replaceAll('.', '-'),
                  '${game.plyCount ~/ 2} moves',
                ].join(' · '),
                style: AppTextStyles.caption,
                overflow: TextOverflow.ellipsis,
              ),
              if (match != null) ...[
                const SizedBox(height: 4),
                Text(_matchLine(match), style: _matchStyle(match)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _matchLine(TwicMatch match) {
    final report = match.report;
    final book = match.bookIsWhite ? 'White' : 'Black';
    final where = '${report.chapterName} ($book)';
    if (match.stayedInBook) {
      return 'Stayed inside $where for the whole game';
    }
    final played = report.playedSan;
    if (match.ranPastYourPrep) {
      return 'Followed $where to move ${report.moveNumber}, then $played — '
          'past where your preparation stops';
    }
    final expected = report.expectedSans.take(3).join(', ');
    return 'Left $where at move ${report.moveNumber} with $played — '
        'you play $expected';
  }

  TextStyle _matchStyle(TwicMatch match) => AppTextStyles.caption.copyWith(
    color: match.testedYourChoice
        ? AppColors.warning
        : AppColors.onSurfaceMuted,
  );

  // ── Details ─────────────────────────────────────────────────────────────

  Widget _details() {
    final game = _c.selected;
    if (game == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Select a game to see it here.\nDouble-click one to open it in '
            'the board viewer.',
            textAlign: TextAlign.center,
            style: AppTextStyles.muted,
          ),
        ),
      );
    }
    final match = _c.matchFor(game);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${game.white} – ${game.black}',
                  style: AppTextStyles.bodyStrong,
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    game.result,
                    if (game.eco.isNotEmpty) game.eco,
                    _eloPair(game),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: AppTextStyles.muted,
                ),
                const SizedBox(height: 10),
                _detailRow('Event', game.event),
                _detailRow('Site', game.site),
                _detailRow('Date', game.date.replaceAll('.', '-')),
                _detailRow('Round', game.round),
                if (game.twicIssue != null)
                  _detailRow('Source', 'TWIC ${game.twicIssue}'),
                if (match != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(_matchLine(match), style: AppTextStyles.body),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Moves', style: AppTextStyles.eyebrow),
                const SizedBox(height: 4),
                SelectableText(game.movetext, style: AppTextStyles.monoDense),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => unawaited(_openInViewer(focus: game)),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Open in Games'),
                ),
              ),
              const SizedBox(width: 8),
              CopyButton.icon(
                tooltip: 'Copy PGN',
                iconSize: 18,
                snackBarMessage: 'PGN copied',
                text: game.toPgn,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 60, child: Text(label, style: AppTextStyles.caption)),
          Expanded(child: Text(value, style: AppTextStyles.body)),
        ],
      ),
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────────

  Widget _footer() {
    final count = _c.visibleGames.length;
    final total = _c.mode == MasterBrowseMode.all ? _c.totalCount : count;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _c.mode == MasterBrowseMode.all
                  ? '${_thousands(total)} games match — showing '
                        '${_thousands(count)}'
                  : '${_thousands(count)} games in your lines',
              style: AppTextStyles.muted,
            ),
          ),
          OutlinedButton.icon(
            onPressed: count == 0 ? null : () => unawaited(_exportPgn()),
            icon: const Icon(Icons.save_alt, size: 16),
            label: const Text('Save as PGN'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: count == 0 ? null : () => unawaited(_openInViewer()),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text('Open ${_thousands(count)} in Games'),
          ),
        ],
      ),
    );
  }

  // ── Formatting ──────────────────────────────────────────────────────────

  static String _name(String pgnName) {
    final comma = pgnName.indexOf(',');
    if (comma <= 0) return pgnName;
    final surname = pgnName.substring(0, comma).trim();
    final rest = pgnName.substring(comma + 1).trim();
    return rest.isEmpty ? surname : '$surname ${rest[0]}.';
  }

  static String _eloPair(MasterGame game) {
    final w = game.whiteElo;
    final b = game.blackElo;
    if (w == null && b == null) return '';
    return '${w ?? '?'}/${b ?? '?'}';
  }

  static String _thousands(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}
