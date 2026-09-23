import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../chess/fen.dart';
import '../chess/generation/tree_wire_v4.dart' show treeWireVersion;
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/maia/maia_model.dart';
import '../engines/maia/move_policy.dart';
import '../engines/stockfish_install.dart';
import '../net/lichess_explorer.dart';
import '../net/lichess_login.dart';
import '../net/lichess_studies.dart';
import '../net/recent_games.dart';
import '../storage/atomic_write.dart';
import '../storage/chapter_files.dart';
import '../storage/eval_cache.dart';
import '../storage/lichess_token.dart';
import '../storage/master_book.dart';
import '../storage/my_accounts.dart';
import '../storage/my_games_files.dart';
import '../storage/pgn_document_store.dart';
import '../storage/pgn_file_import.dart';
import '../storage/pgn_file_picker.dart';
import '../storage/pgn_file_store.dart';
import '../storage/recent_pgn_files.dart';
import '../storage/settings_store.dart';
import '../storage/study_files.dart';
import '../storage/training_store.dart';

/// Where the user's things are: each folder the modes list or write into.
typedef AppFolders = ({
  String repertoires,
  String studies,
  String collections,
  String gamesLibrary,
  ChapterRef tacticsSet,
});

/// Starts a Stockfish with these threads and this table.
typedef EngineLauncher =
    Future<EngineStart> Function({required int cores, required int memoryMb});

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
    required this.store,
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
    required this.lichessExplorer,
    required this.masterBook,
    required this.gameSites,
    required this.accounts,
    required this.progressFiles,
    required this.olderAnalyzed,
    required this.maia,
    required this.launchEngine,
    required this.stopEngines,
    required this.evalCache,
    required this.keepTree,
    this.now = DateTime.now,
    this.jitter = _noJitter,
    this.saveDelay = const Duration(seconds: 1),
    this.explorerDelay = const Duration(milliseconds: 250),
    this.exitWait = const Duration(seconds: 5),
    this.close = _nothingToClose,
  });

  /// The app on this machine: the user's Documents folder and the app's
  /// own [support] folder, the real network, Stockfish and Maia.
  factory AppEnvironment.native({
    required Directory documents,
    required Directory support,
  }) {
    final client = http.Client();
    final engines = EngineSupervisor();
    final maia = MaiaLaunch();
    final book = SqliteMasterBook(p.join(support.path, 'master_games.db'));
    final evalCache = EvalCacheOnDemand(support);
    final repertoires = p.join(documents.path, 'repertoires');
    final studies = p.join(documents.path, 'studies');
    final collections = p.join(documents.path, 'pgn_collections');
    final dice = Random();
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
      store: PgnFileStore(documents: documents, support: support),
      settings: SettingsStore(support: support),
      chapterFiles: ChapterDirectory(Directory(repertoires)),
      studyFiles: StudyDirectory(Directory(studies)),
      libraryPicker: const NativePgnFilePicker(),
      viewerPicker: const NativePgnFilePicker(),
      recentFiles: PreferencesRecentFiles(),
      fileImport: NativePgnFileImport(
        documents: documents.path,
        into: collections,
      ),
      lichessLogin: LichessLoginApi(client, openBrowser: openInBrowser),
      readAccount: readLichessAccount,
      writeAccount: writeLichessAccount,
      lichessStudies: LichessStudyApi(client, token: readLichessToken),
      lichessExplorer: LichessExplorerApi(client, token: readLichessToken),
      masterBook: book,
      gameSites: [
        LichessGamesApi(client, token: readLichessToken),
        ChesscomGamesApi(client),
      ],
      accounts: PreferencesAccounts(),
      progressFiles: TrainingStore(documents),
      olderAnalyzed: () => readOlderAnalyzed(documents),
      maia: maia,
      launchEngine: ({required cores, required memoryMb}) => launchStockfish(
        support: support,
        engines: engines,
        cores: cores,
        memoryMb: memoryMb,
      ),
      stopEngines: engines.dispose,
      evalCache: () => evalCache.cache,
      keepTree: _keepTreeBeside,
      jitter: () => dice.nextDouble() * 2 - 1,
      close: () {
        evalCache.close();
        book.close();
        maia.dispose();
        client.close();
        unawaited(engines.dispose());
      },
    );
  }

  final AppFolders folders;
  final PgnDocumentStore store;

  /// The settings, kept in the support folder, or in memory in a test.
  final SettingsStore settings;
  final ChapterFiles chapterFiles;
  final StudyFiles studyFiles;

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
  final LichessExplorer lichessExplorer;

  /// The old app's master database: TWIC, when the file is there.
  final MasterBook masterBook;

  /// Where the user's own games are downloaded from.
  final List<RecentGames> gameSites;

  /// The user's usernames on those sites.
  final AccountStore accounts;
  final ProgressFiles progressFiles;

  /// The games the old app already mined for puzzles.
  final Future<Set<String>> Function() olderAnalyzed;

  /// The human-move model: the Replies tab, the gaps and the fill.
  final MovePolicy maia;
  final EngineLauncher launchEngine;

  /// Quits every engine; the way out waits for it.
  final Future<void> Function() stopEngines;

  /// The engine's verdicts, shared with the old app, opened the first time
  /// a fill asks.
  final EvalCache Function() evalCache;

  /// Keeps a fill's search tree beside its chapter.
  final Future<void> Function(ChapterRef chapter, String tree) keepTree;

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
    cores: settings.value.engineCores,
    memoryMb: settings.value.engineMemoryMb,
  );
}

double _noJitter() => 0;

void _nothingToClose() {}

/// The tree beside its chapter, where the old app keeps its own:
/// `.cap-generation/<chapter>.pgn/<run>/tree.json`, create-only.
Future<void> _keepTreeBeside(ChapterRef chapter, String tree) async {
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final folder = p.join(
    p.dirname(chapter.path),
    '.cap-generation',
    p.basename(chapter.path),
    'v2-$stamp',
  );
  await Directory(folder).create(recursive: true);
  await replaceFile(p.join(folder, 'tree.json'), utf8.encode(tree));
  log.i('kept the v$treeWireVersion tree of ${chapter.path} in $folder');
}

/// Shows [folder] in the desktop's file manager. A desktop that will not
/// open it is the desktop's failure; the user saw nothing happen, and the
/// log says why.
Future<void> openFolder(Directory folder) async {
  try {
    await folder.create(recursive: true);
    final opened = await launchUrl(Uri.directory(folder.path));
    if (!opened) log.w('open ${folder.path}', 'the desktop declined');
  } on Object catch (error) {
    log.w('open ${folder.path}', error);
  }
}

/// Sends [page] to the desktop's browser and says whether it went. The
/// caller shows the link when it did not; the log says why.
Future<bool> openInBrowser(Uri page) async {
  try {
    final opened = await launchUrl(page, mode: LaunchMode.externalApplication);
    if (!opened)
      log.w('open ${page.host} in the browser', 'the desktop declined');
    return opened;
  } on Object catch (error) {
    log.w('open ${page.host} in the browser', error);
    return false;
  }
}

/// Where the workspace's opponent model comes from: the bundled Maia-3
/// network and its move table, loaded once, the first time anything asks.
///
/// Loading parses a 45 MB graph, so it is not done at start-up on the
/// chance nobody opens a repertoire; and every caller shares the one load,
/// so two panels asking at once do not build two sessions. A model that
/// cannot load answers every question with the reason, once logged, and
/// is not asked to load again: the assets do not change while the app runs.
final class MaiaLaunch implements MovePolicy {
  Future<MaiaLoad>? _loading;

  Future<MaiaLoad> _load() => _loading ??= _loadOnce();

  Future<MaiaLoad> _loadOnce() async {
    try {
      final model = await rootBundle.load('assets/maia3_simplified.onnx');
      final moves = await rootBundle.loadString(
        'assets/data/all_moves_maia3.json',
      );
      final loaded = await MaiaModel.load(
        model: model.buffer.asUint8List(
          model.offsetInBytes,
          model.lengthInBytes,
        ),
        moveVocabulary: moves,
      );
      if (loaded case MaiaUnavailable(:final reason)) {
        log.e('load the Maia model', reason);
      }
      return loaded;
    } on Object catch (error) {
      log.e('read the Maia assets', error);
      return MaiaUnavailable('The opponent model could not be read: $error');
    }
  }

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async => switch (await _load()) {
    MaiaReady(:final model) => model.policy(fen, elo),
    MaiaUnavailable(:final reason) => MaiaFailed(reason),
  };

  void dispose() {
    unawaited(
      _loading?.then((loaded) {
        if (loaded case MaiaReady(:final model)) model.dispose();
      }),
    );
  }
}

/// Where the workspace's Stockfish comes from: the bundled asset, installed
/// once under the support folder, then started under [engines] with the
/// threads and the table the settings give it.
Future<EngineStart> launchStockfish({
  required Directory support,
  required EngineSupervisor engines,
  required int cores,
  required int memoryMb,
}) async {
  final install = StockfishInstall(
    supportDirectory: support,
    readAsset: _readAsset,
  );
  final location = await install.locate();
  if (location case StockfishMissing(:final reason)) {
    log.e('install Stockfish', reason);
  }
  return switch (location) {
    StockfishMissing(:final reason) => StartFailed(reason),
    StockfishReady(:final path) => engines.start(
      path,
      options: {'Threads': '$cores', 'Hash': '$memoryMb'},
    ),
  };
}

/// The bundle has no way to ask whether an asset exists, only to load it.
Future<Uint8List?> _readAsset(String asset) async {
  try {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on FlutterError {
    return null;
  }
}
