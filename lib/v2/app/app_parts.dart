import 'dart:async';

import '../features/settings/lichess_account.dart';
import '../storage/my_games_files.dart';
import '../storage/settings_store.dart';
import '../workspace/books.dart';
import '../workspace/repertoire_catalog.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
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
/// that cross modes, the training modes. Each part is declared after the
/// parts it is built over, and taken down in exactly the reverse order.
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
    required Future<CopyResult?> Function(DocumentSession session) copyOnLeave,
  }) : _question = question,
       _input = input,
       _copyOnLeave = copyOnLeave;

  final AppEnvironment env;
  final DraftQuestion _question;
  final WindowInput _input;

  /// Asks the copy's name and writes it; null when the user gave none.
  final Future<CopyResult?> Function(DocumentSession session) _copyOnLeave;

  SettingsStore get settings => env.settings;
  late final saver = DocumentSaver(
    env.store,
    delay: env.saveDelay,
    pendingWrites: env.pendingWrites,
    books: books,
  );
  late final session = DocumentSession(env.store, saver);
  late final account = LichessAccountState(
    pendingWrites: env.pendingWrites,
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

  /// The user's books and the one in use.
  late final books = Books(
    store: env.books,
    root: env.folders.repertoires,
    pendingWrites: env.pendingWrites,
  );

  late final catalog = RepertoireCatalog(
    files: env.chapterFiles,
    documents: env.store,
    root: env.folders.repertoires,
  );

  late final DocumentModes documents = wireDocumentModes(
    env,
    session,
    saver,
    books,
    catalog,
  );

  late final _workspace = WorkspaceWiring(
    env,
    session: session,
    saver: saver,
    catalog: catalog,
    filter: documents.filter,
    games: gamesCache,
    books: books,
  );
  Workspace get workspace => _workspace.workspace;

  /// The question before the words on screen are left behind.
  late final exit = ExitGuard(
    saver: saver,
    question: _question,
    saveCopy: _copied,
    wait: env.exitWait,
    settleFeatures: env.pendingWrites.settle,
  );

  /// The copy the question on the way out asked for: the name of the file
  /// it wrote, or null. A copy that failed leaves the user where they were,
  /// so the bar says why.
  Future<String?> _copied() async {
    final written = await _copyOnLeave(session);
    if (written is CopySaved) return written.name;
    if (written != null) requests.say(copySaid(written));
    return null;
  }

  late final requests = WorkspaceRequests(
    session: session,
    library: documents.library,
    viewer: documents.viewer,
    games: workspace.games,
    leaving: exit,
    input: _input,
    books: books,
  );

  /// Whether the window fills the screen.
  late final fullScreen = FullScreen(env.setFullScreen, say: requests.say);
  late final _training = TrainingWiring(
    env,
    workspace: workspace,
    catalog: catalog,
    requests: requests,
    games: gamesCache,
  );
  TrainingModes get training => _training.modes;

  /// The labs: the Bughouse lab's owners.
  late final labs = wireLabModes(env);

  bool _disposed = false;
  bool _started = false;
  Future<void>? _starting;

  /// Reads what the app starts from: the repertoires, the settings and the
  /// account, then the engine with the settings it was left with, and the
  /// user's games. A window taken down meanwhile starts nothing more.
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (_disposed || _started) return;
    await settings.load();
    if (_disposed) return;
    _started = true;
    unawaited(documents.library.refresh());
    unawaited(books.load());
    unawaited(training.myGames.load());
    unawaited(account.load());
    unawaited(labs.offer(env.bughouse.bundled));
    await _workspace.start();
  }

  /// Stops producers before the exit guard drains accepted durable work.
  /// Keeping the window open leaves these jobs paused and resumable.
  void prepareToClose() {
    requests.cancelPending();
    workspace.fill.cancel();
    training.myGames.pause();
    training.lines.leave();
    training.puzzles.suspend();
    labs.search.close();
    labs.matches.stop();
    unawaited(account.cancel());
  }

  /// Restore the puzzle's delayed turn when the window stays open.
  void resumeAfterClose() {
    if (!_disposed) training.puzzles.resume();
  }

  /// The parts in the reverse of the order they are declared in, so each
  /// goes before what it was built over; then the environment. A second
  /// call does nothing.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    labs.dispose();
    _training.dispose();
    requests.dispose();
    _workspace.dispose();
    documents.dispose();
    account.dispose();
    books.dispose();
    catalog.dispose();
    env.store.dispose();
    session.dispose();
    saver.dispose();
    // The environment made the settings store, but only the parts listen
    // to it: it goes once they are down, before the environment closes
    // what it opened.
    settings.dispose();
    env.close();
  }
}
