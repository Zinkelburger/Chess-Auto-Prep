import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess/chess.dart' as chess;
import '../models/tactics_position.dart';
import '../models/chess_game.dart';
import '../services/pgn_service.dart';

enum AppMode {
  tactics,
  positionAnalysis,
  pgnViewer,
}

class AppState extends ChangeNotifier {
  AppMode _currentMode = AppMode.tactics;
  List<TacticsPosition> _tacticsPositions = [];
  List<ChessGameModel> _loadedGames = [];
  TacticsPosition? _currentPosition;
  chess.Chess _currentGame = chess.Chess();
  String? _lichessUsername;
  String? _chesscomUsername;
  bool _isLoading = false;
  bool _isAnalysisMode = false;
  bool? _initialBoardFlipped;
  final PgnService _pgnService = PgnService();

  AppMode get currentMode => _currentMode;
  List<TacticsPosition> get tacticsPositions => _tacticsPositions;
  List<ChessGameModel> get loadedGames => _loadedGames;
  TacticsPosition? get currentPosition => _currentPosition;
  chess.Chess get currentGame => _currentGame;
  String? get lichessUsername => _lichessUsername;
  String? get chesscomUsername => _chesscomUsername;
  bool get isLoading => _isLoading;
  bool get isAnalysisMode => _isAnalysisMode;
  bool get boardFlipped => _isAnalysisMode ? (_initialBoardFlipped ?? false) : (_currentGame.turn == chess.Color.BLACK);

  void setMode(AppMode mode) {
    _currentMode = mode;
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

  Future<void> loadUsernames() async {
    final prefs = await SharedPreferences.getInstance();
    _lichessUsername = prefs.getString('lichess_username');
    _chesscomUsername = prefs.getString('chesscom_username');
    notifyListeners();
  }

  Future<void> loadSavedGames() async {
    try {
      final games = await _pgnService.loadImportedGames();
      _loadedGames = games;
      notifyListeners();
    } catch (e) {
      // Ignore errors loading saved games
    }
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

  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void setTacticsPositions(List<TacticsPosition> positions) {
    _tacticsPositions = positions;
    if (positions.isNotEmpty) {
      _currentPosition = positions.first;
    }
    notifyListeners();
  }

  void nextTacticsPosition() {
    if (_tacticsPositions.isEmpty || _currentPosition == null) return;

    final currentIndex = _tacticsPositions.indexOf(_currentPosition!);
    if (currentIndex < _tacticsPositions.length - 1) {
      _currentPosition = _tacticsPositions[currentIndex + 1];
      notifyListeners();
    }
  }

  void removeCurrentTacticsPosition() {
    if (_tacticsPositions.isEmpty || _currentPosition == null) return;

    _tacticsPositions.remove(_currentPosition);

    if (_tacticsPositions.isNotEmpty) {
      _currentPosition = _tacticsPositions.first;
    } else {
      _currentPosition = null;
    }
    notifyListeners();
  }

  void previousTacticsPosition() {
    if (_tacticsPositions.isEmpty || _currentPosition == null) return;

    final currentIndex = _tacticsPositions.indexOf(_currentPosition!);
    if (currentIndex > 0) {
      _currentPosition = _tacticsPositions[currentIndex - 1];
      notifyListeners();
    }
  }

  void setLoadedGames(List<ChessGameModel> games) {
    _loadedGames = games;
    notifyListeners();
  }

  Future<void> saveGames() async {
    if (_loadedGames.isNotEmpty) {
      await _pgnService.saveImportedGames(_loadedGames);
    }
  }

  void setCurrentGame(chess.Chess game) {
    _currentGame = game;
    notifyListeners();
  }

  void setBoardFlipped(bool flipped) {
    _initialBoardFlipped = flipped;
    notifyListeners();
  }

  void enterAnalysisMode() {
    if (!_isAnalysisMode) {
      // Capture current board orientation before entering analysis
      _initialBoardFlipped = _currentGame.turn == chess.Color.BLACK;
      _isAnalysisMode = true;
      notifyListeners();
    }
  }

  void exitAnalysisMode() {
    if (_isAnalysisMode) {
      _isAnalysisMode = false;
      _initialBoardFlipped = null;
      notifyListeners();
    }
  }

  // Move validation callback for tactics
  Function(String)? _onMoveAttempted;

  void setMoveAttemptedCallback(Function(String)? callback) {
    _onMoveAttempted = callback;
  }

  void onMoveAttempted(String moveUci) {
    if (_onMoveAttempted != null) {
      _onMoveAttempted!(moveUci);
    }
  }
}