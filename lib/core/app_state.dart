import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dartchess/dartchess.dart';
import '../services/lichess_auth_service.dart';
import '../utils/safe_change_notifier.dart';

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

  /// Pending repertoire path for builder<->trainer seamless switching.
  /// Set before switching modes; consumed by the target screen on activation.
  String? pendingRepertoirePath;
  String? pendingLineId;

  /// When non-null the builder should open the generation tab in DB Explorer
  /// mode, pre-seeded with these PGN file paths.
  List<String>? pendingGenerationPgnPaths;

  /// FEN to seed the puzzle creator with ("Make puzzle from this position"
  /// hooks in other modes).  Set before switching to tactics mode; consumed
  /// by the tactics panel on activation.
  String? pendingPuzzleSeedFen;

  /// PGN file to open as an external puzzle set ("Review as flashcards" in
  /// Study mode).  Set before switching to tactics mode; consumed by the
  /// tactics panel on activation.
  String? pendingReviewPgnPath;

  /// Restrict the pending review to one PGN game (chapter) index;
  /// null = the whole file.
  int? pendingReviewGameIndex;

  /// Whether the pending review expands variations into extra cards.
  bool pendingReviewIncludeVariations = false;

  /// PGN file to open for editing in Study mode ("Edit set in Study" in
  /// Tactics mode).  Consumed by the study screen on activation.
  String? pendingStudyPath;

  /// PGN file to open in the PGN Viewer ("Open Games in PGN Viewer" in
  /// Player Analysis).  Consumed by the PGN viewer screen on activation.
  String? pendingPgnViewerPath;

  /// Optional position filter applied after opening [pendingPgnViewerPath]:
  /// the viewer slices the collection to games containing this FEN.
  String? pendingPgnViewerSliceFen;

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

  /// Switch to tactics mode and open the puzzle creator seeded with [seedFen].
  void switchToPuzzleCreator({required String seedFen}) {
    pendingPuzzleSeedFen = seedFen;
    _currentMode = AppMode.tactics;
    notifyListeners();
  }

  /// Switch to tactics mode reviewing the PGN file at [path] as a puzzle set
  /// ("Review as flashcards" in Study mode).  [gameIndex] restricts the
  /// review to one chapter; [includeVariations] expands variations into
  /// extra cards.
  void switchToTacticsReview({
    required String path,
    int? gameIndex,
    bool includeVariations = false,
  }) {
    pendingReviewPgnPath = path;
    pendingReviewGameIndex = gameIndex;
    pendingReviewIncludeVariations = includeVariations;
    _currentMode = AppMode.tactics;
    notifyListeners();
  }

  /// Switch to Study mode with the PGN file at [path] opened for editing
  /// ("Edit set in Study" in Tactics mode).
  void switchToStudyEdit({required String path}) {
    pendingStudyPath = path;
    _currentMode = AppMode.study;
    notifyListeners();
  }

  /// Switch to the PGN Viewer with the file at [path] opened, optionally
  /// sliced to games containing [sliceFen] ("Open Games in PGN Viewer" in
  /// Player Analysis).
  void switchToPgnViewer({required String path, String? sliceFen}) {
    pendingPgnViewerPath = path;
    pendingPgnViewerSliceFen = sliceFen;
    _currentMode = AppMode.pgnViewer;
    notifyListeners();
  }

  /// Switch to trainer with a specific repertoire and optional line.
  void switchToTrainer({required String repertoirePath, String? lineId}) {
    pendingRepertoirePath = repertoirePath;
    pendingLineId = lineId;
    _currentMode = AppMode.repertoireTrainer;
    notifyListeners();
  }

  /// Switch to builder with a specific repertoire and optional line to focus.
  void switchToBuilder({required String repertoirePath, String? lineId}) {
    pendingRepertoirePath = repertoirePath;
    pendingLineId = lineId;
    _currentMode = AppMode.repertoire;
    notifyListeners();
  }

  /// Switch to builder and auto-open the generation tab in DB Explorer mode
  /// with the given PGN files pre-loaded.
  void switchToBuilderWithGeneration({
    required String repertoirePath,
    required List<String> pgnPaths,
  }) {
    pendingRepertoirePath = repertoirePath;
    pendingGenerationPgnPaths = pgnPaths;
    pendingLineId = null;
    _currentMode = AppMode.repertoire;
    notifyListeners();
  }

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
