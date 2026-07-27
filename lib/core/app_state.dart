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
}

class AppState extends ChangeNotifier with SafeChangeNotifier {
  AppMode _currentMode = AppMode.tactics;
  Position _currentPosition = Chess.initial;
  String? _lichessUsername;
  String? _chesscomUsername;
  bool _isAnalysisMode = false;
  bool _isRepertoireGenerating = false;
  bool? _initialBoardFlipped;

  // Tactics auto-fetch preferences
  bool _tacticsAutoFetch = false;
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

  /// Park [handoff] and switch to the screen that can deliver it.
  ///
  /// Replaces any handoff still waiting: the newest navigation wins, and a
  /// stale one could otherwise fire on a screen the user has moved past.
  void handOff(PendingHandoff handoff) {
    _pendingHandoff = handoff;
    _currentMode = handoff.targetMode;
    notifyListeners();
  }

  AppMode get currentMode => _currentMode;
  Position get currentPosition => _currentPosition;
  String? get lichessUsername => _lichessUsername;
  String? get chesscomUsername => _chesscomUsername;
  bool get isAnalysisMode => _isAnalysisMode;
  bool get isRepertoireGenerating => _isRepertoireGenerating;
  bool get tacticsAutoFetch => _tacticsAutoFetch;
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

  void setMode(AppMode mode) {
    _currentMode = mode;
    notifyListeners();
  }

  /// Switch to the Repertoire Trainer with the study at [path] loaded as a
  /// tactics-mode training source ("Train" in Study mode).  [lineId]
  /// optionally starts on one chapter's line.
  void switchToStudyTraining({required String path, String? lineId}) =>
      handOff(TrainStudy(sourcePath: path, lineId: lineId));

  /// Switch to Study mode with the PGN file at [path] opened for editing
  /// ("Edit study" in the Repertoire Trainer).
  void switchToStudyEdit({required String path}) =>
      handOff(EditStudy(studyPath: path));

  /// Switch to the PGN Viewer with the file at [path] opened, optionally
  /// sliced to games containing [sliceFen] ("Open Games in PGN Viewer" in
  /// Player Analysis).
  void switchToPgnViewer({required String path, String? sliceFen}) =>
      handOff(OpenPgnViewer(pgnPath: path, sliceFen: sliceFen));

  /// Switch to trainer with a specific repertoire and optional line.
  void switchToTrainer({required String repertoirePath, String? lineId}) =>
      handOff(TrainRepertoire(sourcePath: repertoirePath, lineId: lineId));

  /// Switch to builder with a specific repertoire and optional line to focus.
  /// [moveSequence] navigates the builder board to that position after load
  /// (used by the trainer's "Explore this position").
  void switchToBuilder({
    required String repertoirePath,
    String? lineId,
    List<String>? moveSequence,
  }) => handOff(
    OpenBuilder(
      repertoirePath: repertoirePath,
      lineId: lineId,
      moveSequence: moveSequence,
    ),
  );

  /// Switch to builder and auto-open the generation tab in DB Explorer mode
  /// with the given PGN files pre-loaded.
  void switchToBuilderWithGeneration({
    required String repertoirePath,
    required List<String> pgnPaths,
  }) => handOff(
    OpenBuilder(repertoirePath: repertoirePath, generationPgnPaths: pgnPaths),
  );

  void setLichessUsername(String? username) {
    _lichessUsername = username;
    _saveLichessUsername(username);
    notifyListeners();
  }

  void setChesscomUsername(String? username) {
    _chesscomUsername = username;
    _saveChesscomUsername(username);
    notifyListeners();
  }

  void setTacticsAutoFetch(bool value) {
    _tacticsAutoFetch = value;
    _saveTacticsAutoFetch(value);
    notifyListeners();
  }

  void setLichessLastFetch(DateTime? date) {
    _lichessLastFetch = date;
    _saveLastFetch('lichess_last_fetch_ms', date);
    notifyListeners();
  }

  void setChesscomLastFetch(DateTime? date) {
    _chesscomLastFetch = date;
    _saveLastFetch('chesscom_last_fetch_ms', date);
    notifyListeners();
  }

  Future<void> loadUsernames() async {
    final prefs = await SharedPreferences.getInstance();
    _lichessUsername = prefs.getString('lichess_username');
    _chesscomUsername = prefs.getString('chesscom_username');
    _tacticsAutoFetch = prefs.getBool('tactics_auto_fetch') ?? false;
    final lichessMs = prefs.getInt('lichess_last_fetch_ms');
    _lichessLastFetch = lichessMs != null
        ? DateTime.fromMillisecondsSinceEpoch(lichessMs)
        : null;
    final chesscomMs = prefs.getInt('chesscom_last_fetch_ms');
    _chesscomLastFetch = chesscomMs != null
        ? DateTime.fromMillisecondsSinceEpoch(chesscomMs)
        : null;

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

  Future<void> _saveTacticsAutoFetch(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tactics_auto_fetch', value);
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
