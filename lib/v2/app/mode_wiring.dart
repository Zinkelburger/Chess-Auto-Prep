import '../chess/tactics/game_ids.dart' show GameSite;
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
import '../workspace/workspace.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import 'environment.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// The repertoires, the studies and the PGN Viewer.
DocumentModes wireDocumentModes(
  AppEnvironment env,
  DocumentSession session,
  DocumentSaver saver,
) {
  final library = Library(
    files: env.chapterFiles,
    documents: env.store,
    saver: saver,
    session: session,
    picker: env.libraryPicker,
    root: env.folders.repertoires,
  );
  return DocumentModes(
    library: library,
    outline: ChapterOutline(library: library, session: session),
    studies: Studies(
      files: env.studyFiles,
      documents: env.store,
      session: session,
      saver: saver,
      lichess: env.lichessStudies,
      root: env.folders.studies,
    ),
    viewer: PgnViewer(
      recent: env.recentFiles,
      picker: env.viewerPicker,
      import: env.fileImport,
      settings: env.settings,
      session: session,
      collections: env.folders.collections,
    ),
    autoplay: AutoPlay(session),
  );
}

/// Builds the [TrainingModes] and keeps My games' book in step: it reads
/// the games again when a repertoire changes, or when a download or a new
/// username gives the accounts a new map.
final class TrainingWiring {
  TrainingWiring(
    AppEnvironment env, {
    required Workspace workspace,
    required Library library,
    required WorkspaceRequests requests,
  }) : _library = library {
    final session = workspace.session;
    final tactics = TacticsSet(
      documents: env.store,
      session: session,
      settings: env.settings,
      ref: env.folders.tacticsSet,
      now: env.now,
    );
    // The user's downloaded games, one file per account, shared with the
    // old app.
    games = GamesCache(env.store, folder: env.folders.gamesLibrary);
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
        chapters: ScopeReader(files: env.chapterFiles, documents: env.store),
        files: env.progressFiles,
        analysis: workspace.analysis,
        time: (now: env.now, jitter: env.jitter),
      ),
      myGames: MyGames(
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
      ),
      book: GameBook(
        accounts: env.accounts,
        cache: games,
        shelf: workspace.shelf,
      ),
    );
    _library.addListener(modes.book.recheck);
    modes.myGames.addListener(_gamesMayHaveChanged);
  }

  final Library _library;
  late final TrainingModes modes;

  /// The user's downloaded games, as the review and the book read them.
  late final GamesCache games;

  /// The accounts as the book last heard of them.
  Map<GameSite, Account>? _accountsSeen;

  void _gamesMayHaveChanged() {
    final accounts = modes.myGames.accounts;
    if (identical(accounts, _accountsSeen)) return;
    _accountsSeen = accounts;
    modes.book.recheck();
  }

  void dispose() {
    _library.removeListener(modes.book.recheck);
    modes.myGames.removeListener(_gamesMayHaveChanged);
    modes.dispose();
  }
}
