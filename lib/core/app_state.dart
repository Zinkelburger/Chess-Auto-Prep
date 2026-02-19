import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dartchess/dartchess.dart';
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
  Position _currentPosition = Chess.initial;
  String? _lichessUsername;
  String? _chesscomUsername;
  bool _isLoading = false;
  bool _isAnalysisMode = false;
  bool? _initialBoardFlipped;
  final PgnService _pgnService = PgnService();

  AppMode get currentMode => _currentMode;
  List<ChessGameModel> get loadedGames => _loadedGames;
  Position get currentPosition => _currentPosition;
  String? get lichessUsername => _lichessUsername;
  String? get chesscomUsername => _chesscomUsername;
  bool get isLoading => _isLoading;
  bool get isAnalysisMode => _isAnalysisMode;
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

  Function(String)? _onMoveAttempted;

  void setMoveAttemptedCallback(Function(String)? callback) {
    _onMoveAttempted = callback;
  }

  void onMoveAttempted(String moveUci) {
    if (_isAnalysisMode) {
      _onMoveAttempted?.call(moveUci);
    } else if (_onMoveAttempted != null) {
      _onMoveAttempted!(moveUci);
    }
  }
}
