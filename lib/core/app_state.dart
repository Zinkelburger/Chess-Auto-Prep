import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess/chess.dart' as chess;
import '../models/chess_game.dart';
import '../services/pgn_service.dart';
import '../services/lichess_auth_service.dart';

enum AppMode {
  tactics,
  positionAnalysis,
  repertoire,
  repertoireTrainer,
  pgnViewer,
}

class AppState extends ChangeNotifier {
  AppMode _currentMode = AppMode.tactics;
  List<ChessGameModel> _loadedGames = [];
  chess.Chess _currentGame = chess.Chess();
  String? _lichessUsername;
  String? _chesscomUsername;
  bool _isLoading = false;
  bool _isAnalysisMode = false;
  bool? _initialBoardFlipped;
  final PgnService _pgnService = PgnService();

  AppMode get currentMode => _currentMode;
  List<ChessGameModel> get loadedGames => _loadedGames;
  chess.Chess get currentGame => _currentGame;
  String? get lichessUsername => _lichessUsername;
  String? get chesscomUsername => _chesscomUsername;
  bool get isLoading => _isLoading;
  bool get isAnalysisMode => _isAnalysisMode;
  bool get boardFlipped {
    // In tactics mode, respect the initial board flip (set when loading position)
    if (_currentMode == AppMode.tactics && _initialBoardFlipped != null) {
      return _initialBoardFlipped!;
    }
    // In analysis mode, respect manual flip or default to turn
    if (_isAnalysisMode) {
      return _initialBoardFlipped ?? false;
    }
    // Default fallback (though tactics mode should always hit the first case)
    return _currentGame.turn == chess.Color.BLACK;
  }

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

    // Load Lichess OAuth / PAT tokens (persisted between runs)
    await LichessAuthService().loadTokens();

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

  /// Notify listeners that the current game has changed (without replacing the object)
  /// Use this when making moves on the existing game to avoid board reset/flicker
  void notifyGameChanged() {
    notifyListeners();
  }

  void setBoardFlipped(bool flipped) {
    _initialBoardFlipped = flipped;
    notifyListeners();
  }

  void enterAnalysisMode() {
    if (!_isAnalysisMode) {
      // Don't change board orientation - keep whatever was set when loading the position
      // The _initialBoardFlipped is already set correctly from setBoardFlipped()
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

  // Move validation callback for tactics
  Function(String)? _onMoveAttempted;

  void setMoveAttemptedCallback(Function(String)? callback) {
    _onMoveAttempted = callback;
  }

  void onMoveAttempted(String moveUci) {
    if (_isAnalysisMode) {
      // In analysis mode, call the callback FIRST so it can get the SAN
      // while the move is still legal, then make the move on the game.
      // The PgnViewerWidget will update the position and sync back via
      // onPositionChanged.
      _onMoveAttempted?.call(moveUci);
    } else if (_onMoveAttempted != null) {
      // In tactics mode, validate via callback
      _onMoveAttempted!(moveUci);
    }
  }
}