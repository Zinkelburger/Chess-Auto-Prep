import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dartchess/dartchess.dart';
import '../services/lichess_auth_service.dart';
import '../utils/safe_change_notifier.dart';
import 'pending_handoff.dart';

export 'pending_handoff.dart';

enum AppMode {
  tactics,
  positionAnalysis,
  repertoire,
  repertoireTrainer,
  pgnViewer,
  study,
  engineTournament,
}

extension AppModeLabel on AppMode {
  /// Display name — the single source for the mode menu and the breadcrumb
  /// trail, so a mode is never called two different things.
  String get label => switch (this) {
    AppMode.tactics => 'Tactics',
    AppMode.positionAnalysis => 'Player analysis',
    AppMode.repertoire => 'Repertoire builder',
    AppMode.repertoireTrainer => 'Repertoire trainer',
    // Where your games open. "PGN Viewer" named the file format.
    AppMode.pgnViewer => 'Games',
    AppMode.study => 'Study',
    AppMode.engineTournament => 'Engine tournament',
  };
}

/// The mode menu, grouped by what you are doing rather than listed flat.
/// Also the order of the Ctrl+1…7 shortcuts (see [AppModeShortcut]), so the
/// menu teaches the chord that makes it unnecessary.
const List<({String heading, List<AppMode> modes})> kAppModeGroups = [
  (heading: 'Train', modes: [AppMode.tactics, AppMode.repertoireTrainer]),
  (heading: 'Build', modes: [AppMode.repertoire, AppMode.study]),
  (heading: 'Analyse', modes: [AppMode.pgnViewer, AppMode.positionAnalysis]),
  (heading: 'Lab', modes: [AppMode.engineTournament]),
];

/// Every mode in menu order — what Ctrl+1…7 index into.
final List<AppMode> kAppModeMenuOrder = [
  for (final group in kAppModeGroups) ...group.modes,
];

extension AppModeShortcut on AppMode {
  /// 1-based position in the menu: the digit in this mode's Ctrl+digit chord.
  int get shortcutNumber => kAppModeMenuOrder.indexOf(this) + 1;
}

extension AppModeEngine on AppMode {
  /// Modes whose [IndexedStack] child keeps an interactive engine pane alive.
  /// Leaving these for a lighter mode suspends Stockfish; entering them
  /// resumes it if the user still wants the engine.
  bool get usesInteractiveEngine => switch (this) {
    AppMode.tactics ||
    AppMode.positionAnalysis ||
    AppMode.repertoire ||
    AppMode.pgnViewer ||
    AppMode.study => true,
    // Two engines are already playing each other in there; the analysis pool
    // would only compete with them for the same cores.
    AppMode.repertoireTrainer || AppMode.engineTournament => false,
  };
}

/// Hook through which [AppState] reports navigation to the app-level
/// breadcrumb history. An interface (rather than importing AppHistory) so the
/// dependency points one way and AppState stays constructible without it.
abstract interface class NavigationHistoryRecorder {
  /// A jump that should become a new crumb.
  void recordPush(AppMode mode, PendingHandoff? handoff, String label);

  /// A bare mode switch — erases the trail down to that mode's root.
  void recordReset(AppMode mode);
}

class AppState extends ChangeNotifier with SafeChangeNotifier {
  // Tactics is the app's home: the unified landing screen — recent games on
  // the left, training on the right.
  AppMode _currentMode = AppMode.tactics;
  NavigationHistoryRecorder? _history;
  Position _currentPosition = Chess.initial;
  String? _lichessUsername;
  String? _chesscomUsername;
  bool _usernamesLoaded = false;
  bool _isAnalysisMode = false;
  bool _isRepertoireGenerating = false;
  bool? _initialBoardFlipped;

  // When each account's games were last downloaded (shown on the accounts
  // card). Whether a review runs on startup is one opt-in, and it lives with
  // the review: `recent_games.auto_run`.
  DateTime? _lichessLastFetch;
  DateTime? _chesscomLastFetch;

  /// Work parked for whichever screen the app is switching to, or null when
  /// there is nothing waiting.  See [PendingHandoff] for why this exists.
  PendingHandoff? _pendingHandoff;

  /// Whether a handoff of type [T] is waiting.  Does not consume it — use
  /// [takeHandoff] for that.
  bool hasPending<T extends PendingHandoff>() => _pendingHandoff is T;

  /// Take the pending handoff if it is a [T], clearing it in the same step.
  ///
  /// Reading and clearing are deliberately inseparable: a handoff read but
  /// left in place would re-fire on the next unrelated notification, and every
  /// screen listens to this object.  Returns null when nothing is waiting or
  /// the waiting handoff is for a different screen.
  T? takeHandoff<T extends PendingHandoff>() {
    final handoff = _pendingHandoff;
    if (handoff is! T) return null;
    _pendingHandoff = null;
    return handoff;
  }

  /// Attach the breadcrumb history. Called once by AppHistory's constructor;
  /// AppState never navigates through it, only reports into it.
  void attachHistory(NavigationHistoryRecorder history) => _history = history;

  /// Park [handoff] and switch to the screen that can deliver it.
  ///
  /// Replaces any handoff still waiting: the newest navigation wins, and a
  /// stale one could otherwise fire on a screen the user has moved past.
  ///
  /// Every handoff becomes a breadcrumb; [historyLabel] names it in the trail
  /// (falling back to a label derived from the payload).
  void handOff(PendingHandoff handoff, {String? historyLabel}) {
    _history?.recordPush(
      handoff.targetMode,
      handoff,
      historyLabel ?? handoff.defaultHistoryLabel,
    );
    _pendingHandoff = handoff;
    _currentMode = handoff.targetMode;
    notifyListeners();
  }

  /// Switch modes as a breadcrumb *push* (not a trail reset) without parking
  /// a handoff — for producers that prime the target's app-scoped controller
  /// directly (e.g. "Added to study → Open", which mutates [StudyController]
  /// before switching).
  void pushMode(AppMode mode, {required String historyLabel}) {
    _history?.recordPush(mode, null, historyLabel);
    _pendingHandoff = null;
    _currentMode = mode;
    notifyListeners();
  }

  AppMode get currentMode => _currentMode;
  Position get currentPosition => _currentPosition;
  String? get lichessUsername => _lichessUsername;
  String? get chesscomUsername => _chesscomUsername;

  /// Whether [loadUsernames] has completed. Until then, empty usernames may
  /// just mean "prefs still loading", not "no accounts configured".
  bool get usernamesLoaded => _usernamesLoaded;
  bool get isAnalysisMode => _isAnalysisMode;
  bool get isRepertoireGenerating => _isRepertoireGenerating;
  DateTime? get lichessLastFetch => _lichessLastFetch;
  DateTime? get chesscomLastFetch => _chesscomLastFetch;
  bool get boardFlipped {
    if (_currentMode == AppMode.tactics && _initialBoardFlipped != null) {
      return _initialBoardFlipped!;
    }
    if (_isAnalysisMode) {
      return _initialBoardFlipped ?? false;
    }
    return _currentPosition.turn == Side.black;
  }

  /// Bare mode switch — the mode menu and defensive fallbacks. Erases the
  /// breadcrumb trail down to the new mode's root ("click Tactics and the
  /// history is gone"). Use [pushMode] to keep the trail instead.
  ///
  /// Also drops any still-parked handoff: it belongs to the navigation this
  /// switch abandons, and would otherwise fire the next time its screen is
  /// built — yanking the user back to a file they had navigated away from.
  void setMode(AppMode mode) {
    _history?.recordReset(mode);
    _pendingHandoff = null;
    _currentMode = mode;
    notifyListeners();
  }

  /// Switch to the Repertoire Trainer with the study at [path] loaded as a
  /// tactics-mode training source ("Train" in Study mode).  [lineId]
  /// optionally starts on one chapter's line.
  void switchToStudyTraining({
    required String path,
    String? lineId,
    String? historyLabel,
  }) => handOff(
    TrainStudy(sourcePath: path, lineId: lineId),
    historyLabel: historyLabel,
  );

  /// Switch to Study mode with the PGN file at [path] opened for editing
  /// ("Edit study" in the Repertoire Trainer, the viewer's Edit toggle).
  void switchToStudyEdit({
    required String path,
    int? chapterIndex,
    List<String>? initialSanLine,
    String? historyLabel,
  }) => handOff(
    EditStudy(
      studyPath: path,
      chapterIndex: chapterIndex,
      initialSanLine: initialSanLine,
    ),
    historyLabel: historyLabel,
  );

  /// Switch to the PGN Viewer with the file at [path] opened, optionally
  /// sliced to games containing [sliceFen] ("Open Games in PGN Viewer" in
  /// Player Analysis). [gameId] jumps to one game of the collection, [tab]
  /// picks the side panel it lands on, and [autoAnalyze] starts the engine
  /// review on it.
  void switchToPgnViewer({
    required String path,
    String? sliceFen,
    String? gameId,
    int? gameIndex,
    bool autoAnalyze = false,
    PgnViewerTab tab = PgnViewerTab.game,
    int? ply,
    String? historyLabel,
  }) => handOff(
    OpenPgnViewer(
      pgnPath: path,
      sliceFen: sliceFen,
      gameId: gameId,
      gameIndex: gameIndex,
      autoAnalyze: autoAnalyze,
      tab: tab,
      ply: ply,
    ),
    historyLabel: historyLabel,
  );

  /// Switch to Engine Tournament, optionally selecting one tournament.
  ///
  /// [tournamentId] is its directory name under
  /// `Documents/engine_tournaments` — the same id the MCP tools report.
  void switchToEngineTournament({String? tournamentId, String? historyLabel}) =>
      handOff(
        OpenEngineTournament(tournamentId: tournamentId),
        historyLabel: historyLabel,
      );

  /// Switch to trainer with a specific repertoire and optional line.
  void switchToTrainer({
    required String repertoirePath,
    String? lineId,
    String? historyLabel,
  }) => handOff(
    TrainRepertoire(sourcePath: repertoirePath, lineId: lineId),
    historyLabel: historyLabel,
  );

  /// Switch to builder with a specific repertoire and optional line to focus.
  /// [moveSequence] navigates the builder board to that position after load
  /// (used by the trainer's "Explore this position").
  void switchToBuilder({
    required String repertoirePath,
    String? lineId,
    List<String>? moveSequence,
    String? historyLabel,
  }) => handOff(
    OpenBuilder(
      repertoirePath: repertoirePath,
      lineId: lineId,
      moveSequence: moveSequence,
    ),
    historyLabel: historyLabel,
  );

  /// Switch to builder and auto-open the generation tab in DB Explorer mode
  /// with the given PGN files pre-loaded.
  void switchToBuilderWithGeneration({
    required String repertoirePath,
    required List<String> pgnPaths,
    String? historyLabel,
  }) => handOff(
    OpenBuilder(repertoirePath: repertoirePath, generationPgnPaths: pgnPaths),
    historyLabel: historyLabel,
  );

  void setLichessUsername(String? username) {
    // A different account has a different download history; keeping the old
    // date would date the new name's games to a fetch that never happened.
    if (username?.trim() != _lichessUsername?.trim()) {
      _lichessLastFetch = null;
      unawaited(_saveLastFetch('lichess_last_fetch_ms', null));
    }
    _lichessUsername = username;
    unawaited(_saveLichessUsername(username));
    notifyListeners();
  }

  void setChesscomUsername(String? username) {
    if (username?.trim() != _chesscomUsername?.trim()) {
      _chesscomLastFetch = null;
      unawaited(_saveLastFetch('chesscom_last_fetch_ms', null));
    }
    _chesscomUsername = username;
    unawaited(_saveChesscomUsername(username));
    notifyListeners();
  }

  /// Recorded by the games loader when a site's games are in hand — see
  /// [RecentGamesController]'s `onFetched`. Nothing else writes these: a
  /// second writer is how the accounts card and the games list came to
  /// disagree in the first place.
  void setLichessLastFetch(DateTime? date) {
    _lichessLastFetch = date;
    unawaited(_saveLastFetch('lichess_last_fetch_ms', date));
    notifyListeners();
  }

  void setChesscomLastFetch(DateTime? date) {
    _chesscomLastFetch = date;
    unawaited(_saveLastFetch('chesscom_last_fetch_ms', date));
    notifyListeners();
  }

  Future<void> loadUsernames() async {
    final prefs = await SharedPreferences.getInstance();
    _lichessUsername = prefs.getString('lichess_username');
    _chesscomUsername = prefs.getString('chesscom_username');
    final lichessMs = prefs.getInt('lichess_last_fetch_ms');
    _lichessLastFetch = lichessMs != null
        ? DateTime.fromMillisecondsSinceEpoch(lichessMs)
        : null;
    final chesscomMs = prefs.getInt('chesscom_last_fetch_ms');
    _chesscomLastFetch = chesscomMs != null
        ? DateTime.fromMillisecondsSinceEpoch(chesscomMs)
        : null;

    // Flag + notify before the token load: the Games page only needs the
    // usernames, and secure-storage reads can be slow.
    _usernamesLoaded = true;
    notifyListeners();

    await LichessAuthService.instance.loadTokens();

    notifyListeners();
  }

  Future<void> _saveLichessUsername(String? username) async {
    final prefs = await SharedPreferences.getInstance();
    if (username != null) {
      await prefs.setString('lichess_username', username);
    } else {
      await prefs.remove('lichess_username');
    }
  }

  Future<void> _saveChesscomUsername(String? username) async {
    final prefs = await SharedPreferences.getInstance();
    if (username != null) {
      await prefs.setString('chesscom_username', username);
    } else {
      await prefs.remove('chesscom_username');
    }
  }

  Future<void> _saveLastFetch(String key, DateTime? date) async {
    final prefs = await SharedPreferences.getInstance();
    if (date != null) {
      await prefs.setInt(key, date.millisecondsSinceEpoch);
    } else {
      await prefs.remove(key);
    }
  }

  void setRepertoireGenerating(bool generating) {
    // Called on every generation progress tick — only an actual transition
    // may notify, or everything watching AppState rebuilds at the
    // generator's tick rate for the whole build.
    if (_isRepertoireGenerating == generating) return;
    _isRepertoireGenerating = generating;
    notifyListeners();
  }

  void setCurrentPosition(Position position) {
    _currentPosition = position;
    notifyListeners();
  }

  /// Notify listeners that the current game has changed (without replacing the object)
  void notifyGameChanged() {
    notifyListeners();
  }

  void setBoardFlipped(bool flipped) {
    _initialBoardFlipped = flipped;
    notifyListeners();
  }

  void enterAnalysisMode() {
    if (!_isAnalysisMode) {
      _isAnalysisMode = true;
      notifyListeners();
    }
  }

  void exitAnalysisMode() {
    if (_isAnalysisMode) {
      _isAnalysisMode = false;
      notifyListeners();
    }
  }
}
