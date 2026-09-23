import 'dart:async';

import '../features/settings/lichess_account.dart';
import '../storage/my_games_files.dart';
import '../storage/settings_store.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/workspace.dart';
import 'environment.dart';
import 'exit_guard.dart';
import 'full_screen.dart';
import 'mode.dart';
import 'mode_wiring.dart';
import 'window_input.dart';
import 'workspace_requests.dart';
import 'workspace_wiring.dart';

/// The whole app put together over an [AppEnvironment], in order: the open
/// document and its saver, the document modes, the workspace, the requests
/// that cross modes, the training modes. Taken down in reverse.
///
/// The app builds it over the machine, the window tests over scripted fakes:
/// both run this wiring, so a test of the window is a test of the app as it
/// is put together. How each part is built is its wiring's; this orders
/// them. The window's own questions — what to ask before a draft is left,
/// and the dialogs — come in from whoever draws the window.
final class AppParts {
  AppParts(
    this.env, {
    required DraftQuestion question,
    required WindowInput input,
    required Future<String?> Function(DocumentSession session) copyOnLeave,
  }) : _question = question,
       _input = input,
       _copyOnLeave = copyOnLeave;

  final AppEnvironment env;
  final DraftQuestion _question;
  final WindowInput _input;
  final Future<String?> Function(DocumentSession session) _copyOnLeave;

  SettingsStore get settings => env.settings;
  late final saver = DocumentSaver(env.store, delay: env.saveDelay);
  late final session = DocumentSession(env.store, saver);
  late final account = LichessAccountState(
    login: env.lichessLogin,
    read: env.readAccount,
    write: env.writeAccount,
  );

  /// The user's downloaded games, one file per account, shared with the
  /// old app: the review, the book and the explorer read them.
  late final gamesCache = GamesCache(
    env.store,
    folder: env.folders.gamesLibrary,
  );

  late final DocumentModes documents = wireDocumentModes(env, session, saver);
  late final _workspace = WorkspaceWiring(
    env,
    session: session,
    saver: saver,
    library: documents.library,
    filter: documents.filter,
    games: gamesCache,
  );
  Workspace get workspace => _workspace.workspace;

  /// Whether the window fills the screen.
  late final fullScreen = FullScreen(env.setFullScreen, say: requests.say);

  /// The question before the words on screen are left behind.
  late final exit = ExitGuard(
    saver: saver,
    question: _question,
    saveCopy: () => _copyOnLeave(session),
    wait: env.exitWait,
  );
  late final requests = WorkspaceRequests(
    session: session,
    library: documents.library,
    studies: documents.studies,
    viewer: documents.viewer,
    games: workspace.games,
    leaving: exit,
    input: _input,
  );
  late final _training = TrainingWiring(
    env,
    workspace: workspace,
    library: documents.library,
    requests: requests,
    games: gamesCache,
  );
  TrainingModes get training => _training.modes;

  /// Reads what the app starts from: the repertoires, the settings and the
  /// account, then the engine with the settings it was left with, and the
  /// user's games.
  Future<void> start() async {
    unawaited(documents.library.refresh());
    unawaited(training.myGames.load());
    await settings.load();
    unawaited(account.load());
    await _workspace.start();
  }

  void dispose() {
    requests.dispose();
    _training.dispose();
    _workspace.dispose();
    documents.dispose();
    account.dispose();
    settings.dispose();
    session.dispose();
    saver.dispose();
    env.close();
  }
}
