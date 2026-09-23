import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../chess/tactics/game_ids.dart' show GameSite;
import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/my_games/game_book.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/study/studies.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/set_additions.dart';
import '../features/tactics/tactics_set.dart';
import '../features/trainer/scope_reader.dart';
import '../features/trainer/trainer.dart';
import '../net/lichess_studies.dart';
import '../net/recent_games.dart';
import '../storage/chapter_files.dart';
import '../storage/lichess_token.dart';
import '../storage/my_accounts.dart';
import '../storage/my_games_files.dart';
import '../storage/pgn_file_import.dart';
import '../storage/pgn_file_picker.dart';
import '../storage/recent_pgn_files.dart';
import '../storage/study_files.dart';
import '../storage/training_store.dart';
import '../workspace/workspace.dart';
import 'basics.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// The repertoires, the studies and the PGN Viewer over the real folders.
DocumentModes wireDocumentModes(Basics b) {
  final library = Library(
    files: b.chapterFiles,
    documents: b.store,
    saver: b.saver,
    session: b.session,
    picker: const NativePgnFilePicker(),
    root: b.repertoires,
  );
  return DocumentModes(
    library: library,
    outline: ChapterOutline(library: library, session: b.session),
    studies: Studies(
      files: StudyDirectory(Directory(b.studies)),
      documents: b.store,
      session: b.session,
      saver: b.saver,
      lichess: LichessStudyApi(b.client, token: readLichessToken),
      root: b.studies,
    ),
    viewer: PgnViewer(
      recent: PreferencesRecentFiles(),
      picker: const NativePgnFilePicker(),
      import: NativePgnFileImport(
        documents: b.documents.path,
        into: b.collections,
      ),
      settings: b.settings,
      session: b.session,
      collections: b.collections,
    ),
  );
}

/// Builds the [TrainingModes] and keeps My games' book in step: it reads
/// the games again when a repertoire changes, or when a download or a new
/// username gives the accounts a new map.
final class TrainingWiring {
  TrainingWiring(
    Basics b, {
    required Workspace workspace,
    required Library library,
    required WorkspaceRequests requests,
  }) : _library = library {
    final tactics = TacticsSet(
      documents: b.store,
      session: b.session,
      settings: b.settings,
      ref: ChapterRef.at(
        p.join(b.documents.path, 'tactics_sets', 'Default.pgn'),
      ),
    );
    // The user's downloaded games, one file per account, shared with the
    // old app.
    final games = GamesCache(
      b.store,
      folder: p.join(b.documents.path, 'games_library'),
    );
    final dice = Random();
    modes = TrainingModes(
      tactics: tactics,
      puzzles: PuzzleTrainer(
        set: tactics,
        session: b.session,
        analysis: workspace.analysis,
        settings: b.settings,
        open: (set, game) async =>
            await requests.open(set, game: game) is RequestDone,
      ),
      lines: Trainer(
        session: b.session,
        chapters: ScopeReader(files: b.chapterFiles, documents: b.store),
        files: TrainingStore(b.documents),
        analysis: workspace.analysis,
        time: (now: DateTime.now, jitter: () => dice.nextDouble() * 2 - 1),
      ),
      myGames: MyGames(
        accounts: PreferencesAccounts(),
        sites: [
          LichessGamesApi(b.client, token: readLichessToken),
          ChesscomGamesApi(b.client),
        ],
        cache: games,
        set: SetAdditions(
          documents: b.store,
          session: b.session,
          saver: b.saver,
          set: tactics,
          older: () => readOlderAnalyzed(b.documents),
        ),
        // A Stockfish of its own, with the pane's threads and table.
        engine: b.launchEngine,
      ),
      book: GameBook(
        accounts: PreferencesAccounts(),
        cache: games,
        shelf: workspace.shelf,
      ),
    );
    _library.addListener(modes.book.recheck);
    modes.myGames.addListener(_gamesMayHaveChanged);
  }

  final Library _library;
  late final TrainingModes modes;

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
