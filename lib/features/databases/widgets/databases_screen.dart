/// Everything this app keeps on your disk, on one page.
///
/// Before this existed the answer was spread over four places that did not
/// know about each other: two sections of App settings for master games and
/// your own games, a third for the offline evaluations, and a block inside
/// Bughouse Lab that rendered nothing at all when its book was missing — so
/// the one store you had to fetch by hand was also the one store the app
/// never mentioned. Nothing summed them, so the total the user saw was always
/// smaller than the total their disk saw.
///
/// The page is a list of cards in one fixed form (see [DatabaseCard]), read
/// top to bottom in the order a new install would set them up:
///
///   1. **Master games** — the one that makes repertoire builds better, and
///      the only one with a first-run prompt elsewhere in the app.
///   2. **Your games** — fills itself; here to be seen, not configured.
///   3. **Lichess evaluations** — the recommended offline eval source.
///   4. **ChessDB dump** — the same job, sixty times the disk, Linux only.
///   5. **Bughouse archive** — optional, built outside the app.
///   6. **Caches and leftovers** — what is on disk that no store above claims.
///
/// The last card is the reason the page walks the directories itself rather
/// than asking each store for its own number: a schema migration left a 1.9 GB
/// `.bak` beside the master-games database, and no panel that measures one
/// file it knows the name of could ever have found it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/eval_database_settings.dart';
import '../../../services/eval/cdbdirect_eval_provider.dart';
import '../../../services/eval/cdb_snapshot_download.dart';
import '../../../services/eval/lichess_eval_controller.dart';
import '../../../services/eval/storage_volumes.dart';
import '../../../services/game_store/game_store.dart';
import '../../../services/game_store/game_store_service.dart';
import '../../../services/master_games/master_games_service.dart';
import '../../../services/storage/app_paths.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/open_in_file_manager.dart';
import '../../../utils/time_format.dart';
import '../../../widgets/app_breadcrumb_trail.dart';
import '../../../widgets/app_mode_switcher.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../../../widgets/app_settings_button.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../../../widgets/eval_database_download_card.dart';
import '../../../widgets/eval_database_settings_panel.dart';
import '../../../widgets/lichess_eval_download_card.dart';
import '../../../widgets/lichess_eval_settings_panel.dart';
import '../../../widgets/master_games_settings_panel.dart';
import '../../../utils/number_format.dart';
import '../../bughouse/services/bughouse_book.dart';
import '../services/database_inventory.dart';
import 'database_card.dart';

class DatabasesScreen extends StatefulWidget {
  const DatabasesScreen({super.key});

  @override
  State<DatabasesScreen> createState() => _DatabasesScreenState();
}

class _DatabasesScreenState extends State<DatabasesScreen> {
  final _download = CdbSnapshotDownloadController.instance;
  final _lichess = LichessEvalController.instance;
  final _settings = EvalDatabaseSettings.instance;

  DatabaseInventory _inventory = const DatabaseInventory.empty();
  CdbDirectLibraryStatus? _cdbStatus;
  BughouseBookStatus? _bookStatus;
  Map<String, int> _gameCounts = const {};
  String? _gameStorePath;
  bool _measuring = true;

  @override
  void initState() {
    super.initState();
    _download.addListener(_onChanged);
    _lichess.addListener(_onChanged);
    _settings.addListener(_onChanged);
    // Reads disk only. Nothing here starts a transfer: a page about what you
    // already have must never be the thing that fetches 1.2 TB.
    unawaited(_download.loadSaved());
    unawaited(_lichess.loadSaved());
    unawaited(_measure());
  }

  @override
  void dispose() {
    _download.removeListener(_onChanged);
    _lichess.removeListener(_onChanged);
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// One pass over every directory the app owns.
  ///
  /// Every failure here is a row that says "unknown", never an exception: the
  /// page exists to describe a machine whose storage may well be the thing
  /// that is wrong.
  Future<void> _measure() async {
    if (mounted) setState(() => _measuring = true);

    final support = await _supportPath();
    final book = await _openBookStatus();
    final counts = await _countGames();

    final inventory = support == null
        ? const DatabaseInventory.empty()
        : await readDatabaseInventory(
            supportDirectory: support,
            bughouseBookPath: book?.path,
            lichessEvalsPath: _settings.lichessEvalsPath.isEmpty
                ? null
                : _settings.lichessEvalsPath,
            chessDbDataDirectory: _settings.cdbDirectPath.isEmpty
                ? null
                : _settings.cdbDirectPath,
          );

    final status = await CdbDirectEvalProvider.libraryStatus();
    if (!mounted) return;
    setState(() {
      _inventory = inventory;
      _bookStatus = book;
      _cdbStatus = status;
      _gameCounts = counts.$1;
      _gameStorePath = counts.$2;
      _measuring = false;
    });
  }

  Future<String?> _supportPath() async {
    try {
      return (await AppPaths.supportDirectory()).path;
    } on Object {
      return null;
    }
  }

  Future<BughouseBookStatus?> _openBookStatus() async {
    try {
      return (await BughouseBook.open())?.status;
    } on Object {
      return null;
    }
  }

  Future<(Map<String, int>, String?)> _countGames() async {
    try {
      final store = await GameStoreService.instance.open();
      return (store.collectionCounts(), store.path);
    } on Object {
      return (const <String, int>{}, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final master = context.watch<MasterGamesService>();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const AppBarTitleWithTrail(title: Text('Databases')),
        actions: [
          const AppModeSwitcher(),
          AppOverflowMenu(
            entries: [
              AppMenuEntry(
                label: 'Re-measure what is on disk',
                icon: Icons.refresh,
                enabled: !_measuring,
                onRun: () => unawaited(_measure()),
              ),
              AppMenuEntry(
                label: 'App settings…',
                icon: Icons.settings_outlined,
                dividerAbove: true,
                onRun: () => unawaited(openAppSettings(context)),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _intro(),
                  const SizedBox(height: 16),
                  _masterGamesCard(master),
                  _yourGamesCard(),
                  _lichessCard(),
                  _chessDbCard(),
                  _bughouseCard(),
                  _leftoversCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _intro() {
    final total = _inventory.totalBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _measuring
              ? 'Measuring what is on disk…'
              : 'Chess Auto Prep is using ${formatBytes(total)} on this '
                    'machine. Everything below is optional except your own '
                    'games, which fill themselves as you play.',
          style: AppTextStyles.caption,
        ),
        if (!_measuring && _inventory.directories.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final dir in _inventory.directories) _FolderLink(path: dir),
            ],
          ),
        ],
      ],
    );
  }

  // ── 1. Master games ───────────────────────────────────────────────────────

  Widget _masterGamesCard(MasterGamesService service) {
    final stats = service.stats;
    final has = stats != null && !stats.isEmpty;
    final footprint = _inventory[StoreLabels.masterGames];

    return DatabaseCard(
      title: 'Master games',
      icon: Icons.library_books_outlined,
      whatItIs:
          'Titled-player games from The Week in Chess, kept locally and '
          'indexed by position.',
      whatItBuys:
          'Repertoire builds use real master practice for opponent replies, '
          'model games, and "improves on … in <game>" notes.',
      availability: has
          ? DatabaseAvailability.ready
          : DatabaseAvailability.notSetUp,
      status: has
          ? '${formatThousands(stats.games)} games'
          : (service.isSyncing ? 'Downloading…' : null),
      statusDetail: footprint == null ? null : formatBytes(footprint.bytes),
      freshness: _masterFreshness(service),
      primary: DatabaseAction(
        label: has ? 'Check for new issues' : 'Download master games',
        icon: has ? Icons.refresh : Icons.cloud_download_outlined,
        onRun: () => unawaited(service.sync()),
        disabledReason: service.isSyncing ? 'A download is running.' : null,
      ),
      menu: [
        if (service.isSyncing)
          AppMenuEntry(
            label: 'Stop the download',
            icon: Icons.stop_circle_outlined,
            onRun: service.cancel,
          ),
        // The explorer's "classical OTB only" filter reads per-row counts
        // that a database imported before they existed does not have yet.
        if (has && !service.isRebuildingClassical)
          AppMenuEntry(
            label: service.classicalCountsComplete
                ? 'Rebuild classical index'
                : 'Build classical index',
            icon: Icons.fact_check_outlined,
            onRun: () => unawaited(service.rebuildClassicalIndex()),
          ),
        if (service.isRebuildingClassical)
          AppMenuEntry(
            label: 'Stop the classical index',
            icon: Icons.stop_circle_outlined,
            onRun: service.cancelRebuild,
          ),
        AppMenuEntry(
          label: 'theweekinchess.com',
          icon: Icons.open_in_new,
          onRun: () => unawaited(
            launchUrl(
              Uri.parse('https://theweekinchess.com/twic'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
      ],
      body: _masterProgress(service),
      details: const MasterGamesSettingsPanel(),
    );
  }

  /// When TWIC was last checked and when it will be checked next.
  ///
  /// The weekly auto-sync has worked since it was written; the panel this
  /// replaces simply never said so, which made a database that updates itself
  /// look like one nobody had touched in a month.
  String? _masterFreshness(MasterGamesService service) {
    final last = service.lastCheck;
    if (last == null) return null;
    if (!service.autoSync) return 'Checked ${formatTimeAgo(last)}';
    return 'Checked ${formatTimeAgo(last)} · auto';
  }

  Widget? _masterProgress(MasterGamesService service) {
    final busy = service.isSyncing || service.isRebuildingClassical;
    if (!busy && service.status.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (busy)
          LinearProgressIndicator(
            value: service.fraction > 0 ? service.fraction : null,
            minHeight: 4,
          ),
        const SizedBox(height: 4),
        Text(
          service.status,
          style: TextStyle(
            fontSize: 12,
            color: service.lastError != null
                ? AppColors.danger
                : AppColors.onSurfaceMuted,
          ),
        ),
      ],
    );
  }

  // ── 2. Your games ─────────────────────────────────────────────────────────

  Widget _yourGamesCard() {
    final footprint = _inventory[StoreLabels.yourGames];
    final total = _gameCounts.values.fold(0, (a, b) => a + b);
    return DatabaseCard(
      title: 'Your games',
      icon: Icons.inventory_2_outlined,
      whatItIs:
          'Every game the app downloads or imports, parsed once and indexed '
          'by player, date and opening position.',
      whatItBuys:
          'Feeds tactics from your own games, Player Analysis and the games '
          'library. It fills itself — there is nothing to set up.',
      availability: total > 0
          ? DatabaseAvailability.ready
          : DatabaseAvailability.notSetUp,
      status: total > 0 ? '${formatThousands(total)} games' : 'Empty',
      statusDetail: footprint == null ? null : formatBytes(footprint.bytes),
      body: total == 0
          ? const Text(
              'Downloading your recent games from the Tactics or Player '
              'Analysis screen fills this.',
              style: AppTextStyles.caption,
            )
          : Text(_collectionBreakdown(), style: AppTextStyles.caption),
      menu: [
        if (_gameStorePath != null)
          AppMenuEntry(
            label: 'Show in file manager',
            icon: Icons.folder_open,
            onRun: () => unawaited(openInFileManager(_gameStorePath!)),
          ),
      ],
    );
  }

  String _collectionBreakdown() {
    var tactics = 0, analysis = 0, library = 0, players = 0, users = 0;
    for (final e in _gameCounts.entries) {
      if (e.key == GameCollections.tactics) {
        tactics += e.value;
      } else if (e.key.startsWith('analysis:')) {
        analysis += e.value;
        players++;
      } else if (e.key.startsWith('library:')) {
        library += e.value;
        users++;
      }
    }
    final parts = <String>[
      if (analysis > 0) '$analysis from Player Analysis ($players players)',
      if (library > 0) '$library in the games library ($users accounts)',
      if (tactics > 0) '$tactics in the tactics archive',
    ];
    return parts.isEmpty ? '' : '${parts.join(', ')}.';
  }

  // ── 3. Lichess evaluations ────────────────────────────────────────────────

  Widget _lichessCard() {
    final ready = _lichess.isReady;
    final footprint = _inventory[StoreLabels.lichessEvals];
    return DatabaseCard(
      title: 'Lichess evaluations',
      icon: Icons.storage_outlined,
      recommended: !ready && !_chessDbReady,
      whatItIs:
          'Positions already analysed by Stockfish on the Lichess analysis '
          'board, answered from your disk instead of over the network.',
      whatItBuys:
          'Builds and reviews stop waiting on the engine for positions '
          'somebody has already looked at.',
      availability: ready
          ? DatabaseAvailability.ready
          : DatabaseAvailability.notSetUp,
      status: ready
          ? '${formatCompactCount(_lichess.storedPositions)} positions'
          : null,
      statusDetail: footprint == null ? null : formatBytes(footprint.bytes),
      body: const LichessEvalCard(),
      details: const LichessEvalSettingsPanel(),
      menu: [
        if (_settings.lichessEvalsPath.isNotEmpty)
          AppMenuEntry(
            label: 'Show in file manager',
            icon: Icons.folder_open,
            onRun: () =>
                unawaited(openInFileManager(_settings.lichessEvalsPath)),
          ),
      ],
    );
  }

  // ── 4. The ChessDB dump ───────────────────────────────────────────────────

  bool get _chessDbReady =>
      _settings.enableCdbDirect && _settings.cdbDirectPath.isNotEmpty;

  Widget _chessDbCard() {
    final status = _cdbStatus;
    final reason = status == null ? null : chessDbUnavailableReason(status);
    final footprint = _inventory[StoreLabels.chessDbDump];
    final available = status?.isAvailable ?? false;

    return DatabaseCard(
      title: 'ChessDB dump',
      icon: Icons.dns_outlined,
      whatItIs:
          'The same job as the Lichess evaluations at about sixty times the '
          'size: tens of billions of scored positions, on an SSD you supply.',
      whatItBuys:
          'Worth it only for very large builds. Start with the Lichess '
          'evaluations above — they cover most repertoires.',
      availability: !available
          ? DatabaseAvailability.unavailable
          : (_chessDbReady
                ? DatabaseAvailability.ready
                : DatabaseAvailability.notSetUp),
      unavailableReason: reason,
      status: _chessDbReady ? 'Configured' : null,
      statusDetail: footprint == null ? null : formatBytes(footprint.bytes),
      body: ChessDbDumpCard(
        canDownload: available,
        configured: _chessDbReady,
        cannotDownloadReason: reason,
      ),
      details: EvalDatabaseSettingsPanel(libraryAvailable: available),
      menu: [
        AppMenuEntry(
          label: 'What this is',
          icon: Icons.info_outline,
          onRun: () => showOfflineChessDbInfo(context),
        ),
        if (_settings.cdbDirectPath.isNotEmpty)
          AppMenuEntry(
            label: 'Show in file manager',
            icon: Icons.folder_open,
            onRun: () => unawaited(openInFileManager(_settings.cdbDirectPath)),
          ),
      ],
    );
  }

  // ── 5. The bughouse archive ───────────────────────────────────────────────

  /// The card that justifies the page.
  ///
  /// The FICS book is built by a Python module in this repo, lives outside the
  /// app's own directories, and its panel in Bughouse Lab renders nothing at
  /// all when it is missing. There was therefore no screen in the app from
  /// which a user could learn the book existed. An empty state that says what
  /// the thing is and how to get it is the whole fix.
  Widget _bughouseCard() {
    final book = _bookStatus;
    final footprint = _inventory[StoreLabels.bughouseBook];
    final has = book != null && book.games > 0;

    return DatabaseCard(
      title: 'Bughouse archive',
      icon: Icons.grid_view_outlined,
      whatItIs: has
          ? 'Twenty-one years of FICS bughouse games, indexed by two-board '
                'position.'
          : 'Twenty-one years of FICS bughouse games as an opening book — '
                'what people actually played, next to what the engine likes.',
      whatItBuys:
          'Bughouse Lab shows how often each continuation was played and how '
          'it went. Without it, the Lab has the engine and nothing else.',
      availability: has
          ? DatabaseAvailability.ready
          : DatabaseAvailability.notSetUp,
      status: has ? '${formatThousands(book.games)} games' : null,
      statusDetail: footprint == null ? null : formatBytes(footprint.bytes),
      freshness: has ? '${book.yearRange} · to ${book.maxPly} plies' : null,
      body: has
          ? null
          : const _BuildItYourself(
              blurb:
                  'The archive is a 2.1 GB download from bughouse-db.org that '
                  'is indexed into a 177 MB book. It is built outside the app '
                  'because nothing that large belongs in an installer.',
              command:
                  'python3 -m bughouse_db fetch && '
                  'python3 -m bughouse_db index',
              directory: 'tools/',
            ),
      menu: [
        if (book != null)
          AppMenuEntry(
            label: 'Show in file manager',
            icon: Icons.folder_open,
            onRun: () => unawaited(openInFileManager(book.path)),
          ),
      ],
    );
  }

  // ── 6. Caches and leftovers ───────────────────────────────────────────────

  /// Working files, leftovers, and the quarantine between them.
  ///
  /// Removing a leftover *renames* it into `.trash` rather than unlinking it,
  /// so a mistake is recoverable. That makes the wording load-bearing: a
  /// button that says "delete" and "frees 1.9 GB" while moving a file to a
  /// folder on the same disk would be a page about disk usage telling the one
  /// lie it exists to prevent. So removal is called what it is, the
  /// quarantine is counted in the total like everything else, and emptying it
  /// is a second, explicit action that really does free the space.
  Widget _leftoversCard() {
    final cache = _inventory[StoreLabels.evalCache];
    final strays = _inventory.strays;
    final removable = _inventory.strayBytes;
    final trashed = _inventory.quarantineBytes;

    return DatabaseCard(
      title: 'Caches and leftovers',
      icon: Icons.cleaning_services_outlined,
      whatItIs:
          'Working files the app rebuilds on demand, and anything an upgrade '
          'left behind.',
      whatItBuys:
          'Nothing here is worth keeping if you need the space; removing it '
          'costs at most the time to recompute it.',
      availability: DatabaseAvailability.ready,
      status: formatBytes((cache?.bytes ?? 0) + removable + trashed),
      statusDetail: trashed == 0 ? null : '${formatBytes(trashed)} in .trash',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cache != null)
            Text(
              'Evaluation cache — ${formatBytes(cache.bytes)}. Positions this '
              'machine has already evaluated.',
              style: AppTextStyles.caption,
            ),
          for (final stray in strays) ...[
            const SizedBox(height: 6),
            _StrayRow(stray: stray),
          ],
          if (strays.isEmpty && !_measuring) ...[
            const SizedBox(height: 6),
            const Text('No leftovers found.', style: AppTextStyles.muted),
          ],
          if (trashed > 0) ...[
            const SizedBox(height: 6),
            Text(
              '${formatBytes(trashed)} is waiting in .trash. It still takes '
              'up the space until you empty it.',
              style: AppTextStyles.muted,
            ),
          ],
        ],
      ),
      primary: strays.isEmpty
          ? null
          : DatabaseAction(
              label: 'Move ${formatBytes(removable)} to .trash',
              icon: Icons.delete_outline,
              onRun: () => unawaited(_removeStrays(strays)),
            ),
      secondary: trashed == 0
          ? null
          : DatabaseAction(
              label: 'Empty .trash — frees ${formatBytes(trashed)}',
              icon: Icons.delete_forever_outlined,
              onRun: () => unawaited(_emptyTrash(trashed)),
            ),
    );
  }

  Future<void> _removeStrays(List<StrayFile> strays) async {
    final confirmed = await confirmAction(
      context,
      title:
          'Move ${strays.length} leftover file'
          '${strays.length == 1 ? '' : 's'} to .trash?',
      message:
          'These are copies an upgrade kept and interrupted writes — no '
          'database the app reads is among them. They move to a .trash folder '
          'beside them, so the ${formatBytes(_inventory.strayBytes)} is not '
          'freed until you empty it.',
      confirmLabel: 'Move to .trash',
    );
    if (!confirmed) return;
    for (final stray in strays) {
      await deleteStrayFile(stray);
    }
    await _measure();
  }

  Future<void> _emptyTrash(int bytes) async {
    final confirmed = await confirmAction(
      context,
      title: 'Empty .trash?',
      message:
          'Deletes ${formatBytes(bytes)} for good and frees the space. '
          'Nothing in there can be recovered afterwards.',
      confirmLabel: 'Empty',
    );
    if (!confirmed) return;
    final support = await _supportPath();
    if (support != null) await emptyQuarantine(support);
    await _measure();
  }
}

/// One leftover file: what it is, what it costs, and why it is safe to lose.
class _StrayRow extends StatelessWidget {
  const _StrayRow({required this.stray});

  final StrayFile stray;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.description_outlined,
          size: 14,
          color: AppColors.onSurfaceMuted,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${stray.name} — ${formatBytes(stray.bytes)}',
                style: AppTextStyles.caption,
              ),
              if (stray.reason != null)
                Text(stray.reason!, style: AppTextStyles.muted),
            ],
          ),
        ),
      ],
    );
  }
}

/// The empty state for a store the app cannot fetch for you.
///
/// A shell command is the honest answer here and nowhere else on this page:
/// the bughouse archive genuinely is built by a script in this repo, and the
/// people who want it are running from a checkout. Compare the ChessDB card,
/// which used to print `make setup-cdbdirect` at users of a `.deb` who had no
/// checkout to run it in — that is the case this widget must not become.
class _BuildItYourself extends StatelessWidget {
  const _BuildItYourself({
    required this.blurb,
    required this.command,
    required this.directory,
  });

  final String blurb;
  final String command;
  final String directory;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(blurb, style: AppTextStyles.caption),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.surfaceInset,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  '$directory\$ $command',
                  style: const TextStyle(
                    fontFamily: AppTextStyles.monoFamily,
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy command',
                onPressed: () => unawaited(_copy(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }
}

/// A directory the app writes to, as a link rather than a paragraph of path.
class _FolderLink extends StatelessWidget {
  const _FolderLink({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      icon: const Icon(Icons.folder_outlined, size: 14),
      label: Text(path, style: AppTextStyles.caption),
      onPressed: () => unawaited(openInFileManager(path)),
    );
  }
}
