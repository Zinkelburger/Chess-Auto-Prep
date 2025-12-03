import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess/chess.dart' as chess;
import '../models/tactics_position.dart';
import '../models/chess_game.dart';
import '../services/pgn_service.dart';

enum AppMode {
  tactics,
  positionAnalysis,
  repertoire,
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
      
      // Reset board to current tactic position
      if (_currentPosition != null) {
        _currentGame = chess.Chess.fromFEN(_currentPosition!.fen);
      }
      
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
      // while the move is still legal, then make the move on the game
      print('AppState: Analysis mode - calling callback for $moveUci');
      _onMoveAttempted?.call(moveUci);
      // Don't call _makeMoveFree here - the PgnViewerWidget will update
      // the position and sync back via onPositionChanged
    } else if (_onMoveAttempted != null) {
      // In tactics mode, validate via callback
      _onMoveAttempted!(moveUci);
    }
  }
  
  // Make a move without validation (for analysis mode)
  void _makeMoveFree(String moveUci) {
    if (moveUci.length < 4) return;
    
    final from = moveUci.substring(0, 2);
    final to = moveUci.substring(2, 4);
    String? promotion;
    if (moveUci.length > 4) {
      promotion = moveUci.substring(4, 5);
    }
    
    Map<String, String?> moveMap = {'from': from, 'to': to};
    if (promotion != null) {
      moveMap['promotion'] = promotion;
    }
    
    final success = _currentGame.move(moveMap);
    if (success) {
      notifyListeners();
    }
  }
}