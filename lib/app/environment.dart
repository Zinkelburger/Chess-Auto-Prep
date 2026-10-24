import '../storage/viewer_places.dart';
import '../storage/disk_usage.dart';
import '../storage/pgn_export.dart';
import '../features/tournaments/game_runner.dart';
import '../storage/tournaments.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../chess/tournament/config.dart';
import '../engines/analysis_launch.dart';
import '../storage/settings.dart';
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/hivemind_engine.dart';
import '../engines/maia/move_policy.dart';
import '../engines/stockfish_install.dart';
import '../engines/tournament_launch.dart';
import '../features/settings/app_updates.dart';
import '../net/remote_queue.dart';
import '../net/lichess_explorer.dart';
import '../net/lichess_login.dart';
import '../net/lichess_studies.dart';
import '../net/lichess_study_writes.dart';
import '../net/recent_games.dart';
import '../net/player_ratings.dart';
import '../storage/book_file.dart';
import '../storage/player_files.dart';
import '../storage/text_export.dart';
import '../storage/player_reports.dart';
import '../storage/chapter_files.dart';
import '../storage/chapter_directory.dart';
import '../storage/eval_cache.dart';
import '../storage/audit_store.dart';
import '../storage/finds_store.dart';
import '../storage/generation_trees.dart';
import '../storage/backup_history.dart';
import '../storage/lichess_token.dart';
import '../storage/master_book.dart';
import '../storage/master_corpus.dart';
import '../storage/my_accounts.dart';
import '../storage/pgn_document_store.dart';
import '../storage/pgn_file_import.dart';
import '../storage/pgn_file_picker.dart';
import '../storage/pgn_file_store.dart';
import '../storage/document_repository.dart';
import '../storage/pending_writes.dart';
import '../storage/recent_pgn_files.dart';
import '../storage/settings_store.dart';
import '../storage/viewer_drafts.dart';
import '../storage/study_files.dart';
import '../storage/training_store.dart';
import 'native_desktop.dart';
import 'native_engines.dart';

/// Where the user's things are: each folder the modes list or write into.
typedef AppFolders = ({
  String repertoires,
  String studies,
  String collections,
  String gamesLibrary,
  ChapterRef tacticsSet,
});

/// What the Bughouse mode reaches outside the app: whether this build has
/// the engine at all, and how to start it on so many cores.
typedef BughouseOutside = ({
  Future<bool> Function() bundled,
  Future<HivemindStart> Function({required int cores}) launch,
});

/// Starts a Stockfish with these threads and this table.
typedef EngineLauncher =
    Future<EngineStart> Function({required int cores, required int memoryMb});

/// Starts an engine the user registered, with these threads and this table.
typedef RegisteredEngineLauncher =
    Future<EngineStart> Function(
      TournamentEngine engine, {
      required int cores,
      required int memoryMb,
    });

/// Everything the app reaches outside itself — the files, the network, the
/// engines, the clock — and how long it waits for things, in one value.
///
/// The app runs on [AppEnvironment.native]. The window tests build one of
/// scripted fakes and run the very same wiring over it, so what they check
/// is how the app is put together, not a copy of it. A new way out of the
/// app — a new site, a new file — is a field here and nowhere else.
final class AppEnvironment {
  AppEnvironment({
    required this.folders,
    required PgnDocumentStore store,
    required this.settings,
    required this.chapterFiles,
    required this.studyFiles,
    required this.libraryPicker,
    required this.viewerPicker,
    required this.recentFiles,
    required this.fileImport,
    required this.lichessLogin,
    required this.readAccount,
    required this.writeAccount,
    required this.lichessStudies,
    this.lichessStudyWriter,
    this.openPage = _noPage,
    required this.lichessExplorer,
    required this.masterBook,
    this.masterGames,
    this.masterCorpus = const SqliteMasterCorpus(),
    this.storage,
    this.tournaments,
    this.launchTournament,
    this.pickExecutable = _noFile,
    required this.gameSites,
    required this.accounts,
    required this.progressFiles,
    required this.maia,
    required this.launchEngine,
    this.launchRegisteredEngine = _noRegisteredEngine,
    int? coresAvailable,
    required this.stopEngines,
    required this.evalCache,
    required this.keepTree,
    this.loadTree,
    this.backupHistory,
    this.finds = FindsStore.inMemory,
    this.audits = AuditStore.inMemory,
    RemoteQueue? lookups,
    BookStore? books,
    PlayerStore? players,
    PlayerReports? playerReports,
    this.openingBook = _noOpeningBook,
    this.playerRating,
    this.exportText,
    this.exportPgn,
    this.viewerPlaces,
    this.viewerDrafts,
    required this.setFullScreen,
    required this.bughouse,
    this.updates,
    this.now = DateTime.now,
    this.jitter = _noJitter,
    this.saveDelay = const Duration(seconds: 1),
    this.explorerDelay = const Duration(milliseconds: 250),
    this.exitWait = const Duration(seconds: 5),
    this.close = _nothingToClose,
  }) : store = DocumentRepository(store),
       lookups = lookups ?? RemoteQueue.none(),
       books = books ?? MemoryBooks(),
       players = players ?? MemoryPlayers(),
       playerReports = playerReports ?? PlayerReports(),
       coresAvailable = coresAvailable ?? Platform.numberOfProcessors {
    settings.pendingWrites = pendingWrites;
    this.store.pendingWrites = pendingWrites;
  }

  /// The app on this machine: the user's Documents folder and the app's
  /// own [support] folder, the real network, Stockfish and Maia. Updates
  /// are downloaded under [cache]; without one the app does not update.
  factory AppEnvironment.native({
    required Directory documents,
    required Directory support,
    Directory? cache,
  }) {
    final client = http.Client();
    final engines = EngineSupervisor();
    final maia = MaiaLaunch();
    final masterGames = p.join(support.path, 'master_games.db');
    final evalCache = EvalCacheOnDemand(support);
    final finds = FindsStoreOnDemand(support);
    final audits = AuditStoreOnDemand(support);
    final repertoires = p.join(documents.path, 'repertoires');
    final studies = p.join(documents.path, 'studies');
    final collections = p.join(documents.path, 'pgn_collections');
    final dice = Random();
    final documentsStore = PgnFileStore(documents: documents, support: support);
    return AppEnvironment(
      folders: (
        repertoires: repertoires,
        studies: studies,
        collections: collections,
        gamesLibrary: p.join(documents.path, 'games_library'),
        tacticsSet: ChapterRef.at(
          p.join(documents.path, 'tactics_sets', 'Default.pgn'),
        ),
      ),
      store: documentsStore,
      settings: SettingsStore(support: support),
      chapterFiles: ChapterDirectory(
        Directory(repertoires),
        recovery: documentsStore.recovery,
      ),
      studyFiles: StudyDirectory(
        Directory(studies),
        recovery: documentsStore.recovery,
      ),
      libraryPicker: const NativePgnFilePicker(),
      viewerPicker: const NativePgnFilePicker(),
      recentFiles: PreferencesRecentFiles(),
      fileImport: NativePgnFileImport(
        recovery: documentsStore.recovery,
        documents: documents.path,
        into: collections,
      ),
      lichessLogin: LichessLoginApi(client, openBrowser: openInBrowser),
      readAccount: readLichessAccount,
      writeAccount: writeLichessAccount,
      lichessStudies: LichessStudyApi(client, token: readLichessToken),
      lichessStudyWriter: LichessStudyWriterApi(
        client,
        token: readLichessToken,
      ),
      openPage: openInBrowser,
      lichessExplorer: LichessExplorerApi(client, token: readLichessToken),
      masterBook: SqliteMasterBook(masterGames),
      masterGames: masterGames,
      storage: nativeStoragePlaces(documents: documents, support: support),
      gameSites: [
        LichessGamesApi(client, token: readLichessToken),
        ChesscomGamesApi(client),
      ],
      accounts: PreferencesAccounts(),
      progressFiles: TrainingStore(
        documents,
        support: support,
        recovery: documentsStore.recovery,
      ),
      maia: maia,
      launchEngine: ({required cores, required memoryMb}) => launchStockfish(
        support: support,
        engines: engines,
        cores: cores,
        memoryMb: memoryMb,
      ),
      launchRegisteredEngine: (engine, {required cores, required memoryMb}) =>
          launchAnalysisEngine(
            engine,
            engines: engines,
            cores: cores,
            memoryMb: memoryMb,
          ),
      tournaments: FileTournaments(
        root: Directory(p.join(documents.path, 'engine_tournaments')),
        support: support,
        documents: documentsStore,
      ),
      pickExecutable: pickExecutableFile,
      launchTournament: (spec, transcript) => launchTournamentEngine(
        spec,
        transcript,
        stockfish: StockfishInstall(
          supportDirectory: support,
          readAsset: readBundledAsset,
        ),
        engines: engines,
      ),
      stopEngines: engines.dispose,
      evalCache: () => evalCache.cache,
      keepTree: GenerationTrees(documentsStore.recovery).keep,
      loadTree: GenerationTrees(documentsStore.recovery).startingAt,
      backupHistory: BackupHistory(documentsStore.recovery),
      finds: () => finds.store,
      audits: () => audits.store,
      lookups: RemoteQueue(client),
      books: documentsStore.books,
      players: PlayerFiles(Directory(p.join(documents.path, 'opponents'))),
      playerReports: PlayerReports(
        Directory(p.join(support.path, 'player-reports')),
      ),
      playerRating: PlayerRatings(client).lookup,
      exportText: saveTextExport,
      exportPgn: const PgnExport(),
      viewerPlaces: PreferencesViewerPlaces(),
      viewerDrafts: ViewerDraftFiles(support),
      openingBook: _bundledOpeningBook,
      setFullScreen: setWindowFullScreen,
      bughouse: (
        bundled: bughouseBundled,
        launch: ({required cores}) =>
            launchHivemind(support: support, engines: engines, cores: cores),
      ),
      updates: cache == null ? null : nativeUpdates(client, cache),
      jitter: () => dice.nextDouble() * 2 - 1,
      close: () {
        evalCache.close();
        finds.close();
        audits.close();
        maia.dispose();
        client.close();
        unawaited(engines.dispose());
      },
    );
  }

  final pendingWrites = PendingWrites();
  final AppFolders folders;
  final DocumentRepository store;

  /// The settings, kept in the support folder, or in memory in a test.
  final SettingsStore settings;
  final ChapterFiles chapterFiles;
  final StudyFiles studyFiles;

  /// The native Save dialog for an explicitly exported prep sheet.
  final Future<String?> Function(String name, String text)? exportText;
  final PgnExport? exportPgn;
  final ViewerPlaces? viewerPlaces;

  /// Where unsaved viewer edits are kept against a crash; none in a test
  /// that does not ask for them.
  final ViewerDrafts? viewerDrafts;

  /// The file dialogs of the builder's import and of the PGN Viewer.
  final PgnFilePicker libraryPicker;
  final PgnFilePicker viewerPicker;
  final RecentFiles recentFiles;
  final PgnFileImport fileImport;

  final LichessLogin lichessLogin;

  /// The Lichess account as it is kept between runs.
  final Future<LichessAccount?> Function() readAccount;
  final Future<bool> Function(LichessAccount?) writeAccount;
  final LichessStudies lichessStudies;

  /// Writes studies to the user's Lichess account; none in the window tests
  /// unless one is scripted.
  final LichessStudyWriter? lichessStudyWriter;

  /// Shows a page in the desktop's browser and says whether it went.
  final Future<bool> Function(Uri page) openPage;
  final LichessExplorer lichessExplorer;

  /// The master games database read as an opening book.
  final MasterBook masterBook;

  /// Where the master games database is kept, downloaded into and imported
  /// into; null where there is none.
  final String? masterGames;
  final MasterCorpus masterCorpus;

  /// What the Databases mode measures on disk, and which derived databases'
  /// leftovers it may delete; null in tests that do not measure.
  final StoragePlaces? storage;

  /// Where the user's own games are downloaded from.
  final List<RecentGames> gameSites;

  /// The user's usernames on those sites.
  final AccountStore accounts;
  final ProgressFiles progressFiles;

  /// The human-move model: the Replies tab, the gaps and the fill.
  final MovePolicy maia;
  final EngineLauncher launchEngine;

  /// Starts an engine registered in Engine tournament for the analysis.
  final RegisteredEngineLauncher launchRegisteredEngine;

  /// The cores this computer has: half of them is the engine's default.
  final int coresAvailable;
  final TournamentStore? tournaments;
  final TournamentLauncher? launchTournament;

  /// The file dialog that picks an engine binary to register.
  final Future<String?> Function() pickExecutable;

  /// Quits every engine; the way out waits for it.
  final Future<void> Function() stopEngines;

  /// The engine's stored verdicts, opened the first time a fill asks.
  final EvalCache Function() evalCache;

  /// What the searches point out, kept between runs, opened the first time
  /// one is recorded or listed. Called once; the default keeps them in
  /// memory, for a test.
  final FindsStore Function() finds;

  /// The audit's kept engine lines and dismissed findings, opened the
  /// first time an audit asks; in memory for a test.
  final AuditStore Function() audits;

  /// ChessDB and the Lichess cloud, asked one request at a time by every
  /// run that opts into them: the one client the app has for either.
  final RemoteQueue lookups;

  /// The user's books, `books.json` in the support folder; in memory for
  /// a test.
  final BookStore books;
  final PlayerStore players;
  final PlayerReports playerReports;

  /// The text of each volume of the bundled opening book; none in a test.
  final Future<List<String>> Function() openingBook;
  final Future<PlayerRating> Function(String id)? playerRating;

  /// Keeps a fill's search tree beside its chapter.
  final TreeKeeper keepTree;
  final TreeLoader? loadTree;
  final BackupHistory? backupHistory;

  /// Puts the window in or out of full screen.
  final Future<void> Function(bool on) setFullScreen;

  /// The Bughouse mode's engine.
  final BughouseOutside bughouse;

  /// GitHub releases, the downloads and the install helper; null where the
  /// app does not update itself, as in tests.
  final UpdateOutside? updates;

  /// The clock the tactics set and the trainer schedule by.
  final DateTime Function() now;

  /// The trainer's spread of review dates, in −1…1.
  final double Function() jitter;

  /// How long a draft waits before it is written.
  final Duration saveDelay;

  /// How long the explorer waits for the cursor to settle.
  final Duration explorerDelay;

  /// How long the way out waits for a write before it asks.
  final Duration exitWait;

  /// Closes what this opened: the network, the databases, the engines.
  final void Function() close;

  /// A Stockfish with the threads and the table the settings give it now.
  Future<EngineStart> startEngine() => launchEngine(
    cores: settings.value.coresOn(coresAvailable),
    memoryMb: settings.value.engineMemoryMb,
  );

  /// The engine the board's analysis runs: the one chosen under Settings ▸
  /// Engine, with the same threads and table as Stockfish. One that is no
  /// longer registered, or does not start, gives way to the bundled
  /// Stockfish, which says so; the analysis never goes without an engine
  /// for want of the chosen one.
  Future<EngineStart> startAnalysisEngine() async {
    final s = settings.value;
    final id = s.analysisEngine;
    if (id == Settings.builtInEngine) return startEngine();
    final engine = await _registered(id);
    if (engine == null) {
      log.w('start the analysis engine', 'no registered engine has id $id');
      return _builtInInstead('The chosen engine is no longer registered');
    }
    final started = await launchRegisteredEngine(
      engine,
      cores: s.coresOn(coresAvailable),
      memoryMb: s.engineMemoryMb,
    );
    if (started case StartFailed(:final reason)) {
      log.w('start ${engine.name} for analysis', reason);
      return _builtInInstead('${engine.name} did not start: $reason');
    }
    return started;
  }

  Future<TournamentEngine?> _registered(String id) async {
    final registry = await tournaments?.engines();
    if (registry case TournamentFailed(:final message)) {
      log.w('read the engine registry for analysis', message);
    }
    return switch (registry) {
      TournamentSaved(:final value) =>
        value.where((e) => e.id == id && analysesBoard(e)).firstOrNull,
      _ => null,
    };
  }

  Future<EngineStart> _builtInInstead(String notice) async =>
      switch (await startEngine()) {
        Started(:final engine) => Started(engine, notice: notice),
        StartFailed(:final reason) => StartFailed('$notice. $reason'),
      };

  /// Hivemind on half of this machine's cores, not the Stockfish setting,
  /// which the user may have turned down: a network engine on one core
  /// takes a minute over what it otherwise answers in ten seconds.
  Future<HivemindStart> startHivemind() =>
      bughouse.launch(cores: max(1, coresAvailable ~/ 2));
}

double _noJitter() => 0;

Future<List<String>> _noOpeningBook() async => const [];

/// The lichess opening TSVs bundled under `assets/data/openings/`.
Future<List<String>> _bundledOpeningBook() => Future.wait([
  for (final volume in const ['a', 'b', 'c', 'd', 'e'])
    rootBundle.loadString('assets/data/openings/$volume.tsv'),
]);

void _nothingToClose() {}

Future<EngineStart> _noRegisteredEngine(
  TournamentEngine engine, {
  required int cores,
  required int memoryMb,
}) async => const StartFailed('No registered engines here.');

Future<String?> _noFile() async => null;

Future<bool> _noPage(Uri page) async => false;

/// Everything the app keeps, as the Databases mode measures it. Only the
/// master games, which can be downloaded and imported again, and leftovers
/// of derived databases can be deleted there; the evaluation cache (held
/// open while the app runs) and everything the user made are measured only.
StoragePlaces nativeStoragePlaces({
  required Directory documents,
  required Directory support,
}) {
  String doc(String name) => p.join(documents.path, name);
  String sup(String name) => p.join(support.path, name);
  return (
    support: support.path,
    derived: const ['master_games.db', 'eval_cache.db'],
    stores: [
      (name: 'Master games', path: sup('master_games.db'), removable: true),
      (
        name: 'Engine evaluations',
        path: sup('eval_cache.db'),
        removable: false,
      ),
      (name: 'Search finds', path: sup('finds.db'), removable: false),
      (name: 'Chapter audits', path: sup('audit.db'), removable: false),
      (
        name: 'Dismissed audit findings',
        path: sup('audit_dismissed.db'),
        removable: false,
      ),
      (name: 'Kept versions', path: sup('backups'), removable: false),
      (name: 'Bughouse engine', path: sup('bughouse'), removable: false),
      (name: 'Repertoires', path: doc('repertoires'), removable: false),
      (name: 'Studies', path: doc('studies'), removable: false),
      (name: 'PGN collections', path: doc('pgn_collections'), removable: false),
      (name: 'Games library', path: doc('games_library'), removable: false),
      (name: 'Tactics', path: doc('tactics_sets'), removable: false),
      (
        name: 'Engine tournaments',
        path: doc('engine_tournaments'),
        removable: false,
      ),
    ],
  );
}
