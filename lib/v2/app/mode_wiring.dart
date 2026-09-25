import '../chess/tactics/game_ids.dart' show GameSite;
import '../features/bughouse/archive_moves.dart';
import '../features/bughouse/bughouse_lab.dart';
import '../features/bughouse/matches.dart';
import '../features/bughouse/table_search.dart';
import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/my_games/game_book.dart';
import '../features/pgn_viewer/auto_play.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/studies.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/set_additions.dart';
import '../features/tactics/tactics_set.dart';
import '../features/trainer/trainer.dart';
import '../storage/my_accounts.dart';
import '../storage/my_games_files.dart';
import '../workspace/books.dart';
import '../workspace/repertoire_catalog.dart';
import '../workspace/local_games.dart';
import '../workspace/workspace.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/file_filter.dart';
import 'environment.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// The repertoires, the studies and the PGN Viewer.
DocumentModes wireDocumentModes(
  AppEnvironment env,
  DocumentSession session,
  DocumentSaver saver,
  Books books,
  RepertoireCatalog catalog, {
  LibraryTrainingGuard? withTrainingRetired,
}) {
  final library = Library(
    files: env.chapterFiles,
    pendingWrites: env.pendingWrites,
    withTrainingRetired: withTrainingRetired,
    catalog: catalog,
    documents: env.store,
    saver: saver,
    session: session,
    picker: env.libraryPicker,
    root: env.folders.repertoires,
    books: books,
    now: env.now,
  );
  final filter = FileFilter(session);
  return DocumentModes(
    library: library,
    outline: ChapterOutline(library: library, session: session),
    studies: Studies(
      pendingWrites: env.pendingWrites,
      files: env.studyFiles,
      documents: env.store,
      session: session,
      saver: saver,
      lichess: env.lichessStudies,
      root: env.folders.studies,
    ),
    viewer: PgnViewer(
      pendingWrites: env.pendingWrites,
      recent: env.recentFiles,
      picker: env.viewerPicker,
      import: env.fileImport,
      settings: env.settings,
      session: session,
      filter: filter,
      collections: env.folders.collections,
    ),
    filter: filter,
    autoplay: AutoPlay(session),
  );
}

/// Builds the [TrainingModes] and keeps My games' book in step: it reads
/// the games again when the repertoires are listed anew, or when a download
/// or a new username gives the accounts a new map — which the explorer's
/// `My games` hears too.
final class TrainingWiring {
  TrainingWiring(
    AppEnvironment env, {
    required Workspace workspace,
    required RepertoireCatalog catalog,
    required WorkspaceRequests requests,
    required this.games,
  }) : _myGamesTree = workspace.myGamesTree {
    final session = workspace.session;
    final tactics = TacticsSet(
      documents: env.store,
      session: session,
      settings: env.settings,
      ref: env.folders.tacticsSet,
      now: env.now,
    );
    modes = TrainingModes(
      tactics: tactics,
      puzzles: PuzzleTrainer(
        set: tactics,
        session: session,
        analysis: workspace.analysis,
        settings: env.settings,
        open: (set, game) async =>
            await requests.open(set, game: game) is RequestDone,
        now: env.now,
      ),
      lines: Trainer(
        session: session,
        chapters: ScopeReader(
          files: env.chapterFiles,
          documents: env.store,
          catalog: catalog,
        ),
        files: env.progressFiles,
        analysis: workspace.analysis,
        time: (now: env.now, jitter: env.jitter),
        books: workspace.books,
        catalog: catalog,
        pendingWrites: env.pendingWrites,
      ),
      myGames: MyGames(
        pendingWrites: env.pendingWrites,
        accounts: env.accounts,
        sites: env.gameSites,
        cache: games,
        set: SetAdditions(
          documents: env.store,
          session: session,
          saver: workspace.saver,
          set: tactics,
          older: env.olderAnalyzed,
        ),
        // A Stockfish of its own, with the pane's threads and table.
        engine: env.startEngine,
        now: env.now,
      ),
      book: GameBook(
        accounts: env.accounts,
        cache: games,
        shelf: workspace.shelf,
        books: workspace.books,
      ),
    );
    _catalog = catalog;
    _catalog.addListener(modes.book.recheck);
    modes.myGames.addListener(_gamesMayHaveChanged);
  }

  final LocalGames _myGamesTree;
  late final TrainingModes modes;
  late final RepertoireCatalog _catalog;

  /// The user's downloaded games, one file per account, shared with the
  /// old app: what the review, the book and the explorer read.
  final GamesCache games;

  /// The accounts as the book last heard of them.
  Map<GameSite, Account>? _accountsSeen;

  void _gamesMayHaveChanged() {
    final accounts = modes.myGames.accounts;
    if (identical(accounts, _accountsSeen)) return;
    _accountsSeen = accounts;
    modes.book.recheck();
    _myGamesTree.forget();
  }

  void dispose() {
    _catalog.removeListener(modes.book.recheck);
    modes.myGames.removeListener(_gamesMayHaveChanged);
    modes.dispose();
  }
}

/// The Bughouse lab over the environment's engine and books.
LabModes wireLabModes(AppEnvironment env) {
  final lab = BughouseLab();
  final search = TableSearch(
    pendingWrites: env.pendingWrites,
    lab: lab,
    book: env.bughouse.hivemindBook,
    startEngine: env.startHivemind,
  );
  return LabModes(
    lab: lab,
    search: search,
    archive: ArchiveMoves(lab: lab, book: env.bughouse.ficsBook),
    // A Hivemind of its own for each run, so the tables keep theirs.
    matches: Matches(
      pendingWrites: env.pendingWrites,
      store: env.bughouse.matches,
      startEngine: env.startHivemind,
      lab: lab,
      tables: search,
      now: env.now,
    ),
  );
}
