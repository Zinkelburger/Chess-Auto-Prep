// Centralized repertoire session state shared across board, PGN, engine, and tree.
// This was extracted from the repertoire screen so it can be reused (e.g., trainer).
// It owns the canonical chess state: move history, current ply index, derived FEN,
// and synchronizes the opening tree and parsed repertoire lines.
import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../services/move_analysis_pool.dart';
import '../services/opening_tree_builder.dart';
import '../services/repertoire_service.dart';
import '../utils/pgn_utils.dart' as pgn_utils;

/// Manages repertoire state and acts as the single source of truth.
/// All UI components should derive their chess position from this class.
class RepertoireController with ChangeNotifier {
  Map<String, dynamic>? _currentRepertoire;
  Map<String, dynamic>? get currentRepertoire => _currentRepertoire;

  String? _repertoirePgn;
  String? get repertoirePgn => _repertoirePgn;

  OpeningTree? _openingTree;
  OpeningTree? get openingTree => _openingTree;

  List<RepertoireLine> _repertoireLines = [];
  List<RepertoireLine> get repertoireLines => _repertoireLines;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  bool _isRepertoireWhite = true;
  bool get isRepertoireWhite => _isRepertoireWhite;

  bool _needsColorSelection = false;
  bool get needsColorSelection => _needsColorSelection;

  /// The canonical move history - source of truth for position.
  List<String> _moveHistory = [];
  List<String> get moveHistory => List.unmodifiable(_moveHistory);

  /// Current move index (-1 = starting position, 0 = after first move, etc.)
  int _currentMoveIndex = -1;
  int get currentMoveIndex => _currentMoveIndex;

  /// Derived position from move history.
  Position _position = Chess.initial;
  Position get position => _position;
  String get fen => _position.fen;

  /// Starting FEN if different from standard position (for PGN FEN header).
  String? _startingFen;
  String? get startingFen => _startingFen;

  /// Get current move sequence (moves up to current index).
  List<String> get currentMoveSequence {
    if (_currentMoveIndex < 0) return [];
    return _moveHistory.sublist(0, _currentMoveIndex + 1);
  }

  // Flag to prevent update loops between board and PGN editor.
  bool _isInternalUpdate = false;
  bool get isInternalUpdate => _isInternalUpdate;

  /// Called when user makes a move on the board or clicks an explorer move.
  /// The move has already been validated by the caller (e.g., ChessBoardWidget).
  /// This is the entrypoint for new moves.
  void userPlayedMove(String sanMove) {
    // If we're not at the end of the line, check if this creates a variation.
    if (_currentMoveIndex < _moveHistory.length - 1) {
      final existingNextMove = _moveHistory[_currentMoveIndex + 1];
      if (existingNextMove == sanMove) {
        _currentMoveIndex++;
        _rebuildPosition();
        _syncOpeningTree();
        notifyListeners();
        return;
      }
      _moveHistory = _moveHistory.sublist(0, _currentMoveIndex + 1);
    }

    _moveHistory.add(sanMove);
    _currentMoveIndex++;

    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Called when user selects a move in the opening tree.
  void userSelectedTreeMove(String sanMove) {
    if (_openingTree == null) return;

    final branchIndex = _openingTree!.currentDepth;

    if (branchIndex < _moveHistory.length) {
      _moveHistory = _moveHistory.sublist(0, branchIndex);
    }

    _moveHistory.add(sanMove);
    _currentMoveIndex = _moveHistory.length - 1;

    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Jump to a specific move index in the history (-1 = starting position).
  void jumpToMoveIndex(int index) {
    if (index < -1 || index >= _moveHistory.length) return;
    if (index == _currentMoveIndex) return;

    _currentMoveIndex = index;
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  void goBack() {
    if (_currentMoveIndex >= 0) {
      jumpToMoveIndex(_currentMoveIndex - 1);
    }
  }

  void goForward() {
    if (_currentMoveIndex < _moveHistory.length - 1) {
      jumpToMoveIndex(_currentMoveIndex + 1);
    }
  }

  void goToStart() {
    jumpToMoveIndex(-1);
  }

  void goToEnd() {
    jumpToMoveIndex(_moveHistory.length - 1);
  }

  /// Replace current history with provided moves.
  void loadMoveHistory(List<String> moves) {
    _moveHistory = List.from(moves);
    _currentMoveIndex = moves.isEmpty ? -1 : moves.length - 1;
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Clear the current line.
  void clearMoveHistory() {
    _moveHistory.clear();
    _currentMoveIndex = -1;
    _position = _startingFen != null
        ? Chess.fromSetup(Setup.parseFen(_startingFen!))
        : Chess.initial;
    _startingFen = null;
    _syncOpeningTree();
    notifyListeners();
  }

  /// Set the board position from a FEN string.
  /// Returns true if the FEN was valid and position was set.
  bool setPositionFromFen(String fen) {
    try {
      final trimmedFen = fen.trim();
      if (trimmedFen.isEmpty) return false;

      final newPos = Chess.fromSetup(Setup.parseFen(trimmedFen));

      _position = newPos;
      _moveHistory.clear();
      _currentMoveIndex = -1;

      const standardFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      if (trimmedFen != standardFen && !trimmedFen.startsWith(standardFen.split(' ')[0])) {
        _startingFen = trimmedFen;
      } else {
        _startingFen = null;
      }

      _selectedPgnLine = null;

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Invalid FEN: $e');
      return false;
    }
  }

  /// Rebuild the chess position from move history up to current index.
  void _rebuildPosition() {
    Position pos;
    if (_startingFen != null) {
      try {
        pos = Chess.fromSetup(Setup.parseFen(_startingFen!));
      } catch (_) {
        pos = Chess.initial;
      }
    } else {
      pos = Chess.initial;
    }
    for (int i = 0; i <= _currentMoveIndex && i < _moveHistory.length; i++) {
      final move = pos.parseSan(_moveHistory[i]);
      if (move == null) break;
      pos = pos.play(move);
    }
    _position = pos;
  }

  /// Sync the opening tree to match current move history.
  void _syncOpeningTree() {
    if (_openingTree != null) {
      _openingTree!.syncToMoveHistory(currentMoveSequence);
    }
  }

  /// Sets a new repertoire and triggers loading.
  Future<void> setRepertoire(Map<String, dynamic> repertoire) async {
    _currentRepertoire = repertoire;
    await loadRepertoire();
  }

  /// Writes the color header to the PGN file and reloads.
  Future<void> setRepertoireColor(bool isWhite) async {
    if (_currentRepertoire == null) return;
    final filePath = _currentRepertoire!['filePath'] as String;
    final file = io.File(filePath);
    if (!await file.exists()) return;

    final colorLabel = isWhite ? 'White' : 'Black';
    final existing = await file.readAsString();
    await file.writeAsString('// Color: $colorLabel\n$existing');
    _needsColorSelection = false;
    await loadRepertoire();
  }

  /// (Re)loads the PGN content for the current repertoire.
  Future<void> loadRepertoire() async {
    if (_currentRepertoire == null) return;
    _setLoading(true);

    try {
      final filePath = _currentRepertoire!['filePath'] as String;
      final file = io.File(filePath);

      if (await file.exists()) {
        _repertoirePgn = await file.readAsString();

        _position = Chess.initial;
        _moveHistory.clear();
        _currentMoveIndex = -1;
        _startingFen = null;

        await _buildOpeningTree();
        await _parseRepertoireLines();
      } else {
        _repertoirePgn = null;
        _openingTree = null;
        _repertoireLines = [];
        _position = Chess.initial;
        _moveHistory.clear();
        _currentMoveIndex = -1;
        _startingFen = null;
      }
    } catch (e) {
      debugPrint('Failed to load repertoire: $e');
      _repertoirePgn = null;
      _openingTree = null;
      _repertoireLines = [];
      _position = Chess.initial;
      _moveHistory.clear();
      _currentMoveIndex = -1;
      _startingFen = null;
    } finally {
      _setLoading(false);

      MoveAnalysisPool().warmUp();
    }
  }

  /// Parses repertoire lines for PGN browser.
  Future<void> _parseRepertoireLines() async {
    if (_repertoirePgn == null || _repertoirePgn!.isEmpty) {
      _repertoireLines = [];
      return;
    }

    try {
      final service = RepertoireService();
      _repertoireLines = service.parseRepertoirePgn(_repertoirePgn!);
      debugPrint('Parsed ${_repertoireLines.length} repertoire lines for PGN browser');
    } catch (e) {
      debugPrint('Failed to parse repertoire lines: $e');
      _repertoireLines = [];
    }
  }

  /// Builds an opening tree from the current repertoire PGN.
  Future<void> _buildOpeningTree() async {
    if (_repertoirePgn == null || _repertoirePgn!.isEmpty) {
      _openingTree = OpeningTree();
      return;
    }

    try {
      String? repertoireColor;
      final lines = _repertoirePgn!.split('\n');

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.startsWith('// Color:')) {
          repertoireColor = trimmedLine.substring(9).trim();
          break;
        }
      }

      _needsColorSelection = repertoireColor == null;
      final isWhiteRepertoire = repertoireColor != 'Black';
      _isRepertoireWhite = isWhiteRepertoire;

      final processedGames = <String>[];

      String? currentEvent;
      String? currentDate;
      String? currentWhite;
      String? currentBlack;
      String? currentResult;
      final moveLines = <String>[];

      for (final line in lines) {
        final trimmedLine = line.trim();

        if (trimmedLine.startsWith('//')) {
          continue;
        }

        if (trimmedLine.startsWith('[Event ')) {
          if (currentEvent != null && moveLines.isNotEmpty) {
            final game = _buildGame(currentEvent, currentDate, currentWhite, currentBlack, currentResult, moveLines);
            if (game != null) {
              processedGames.add(game);
            }
          }

          currentEvent = _extractHeaderValue(trimmedLine);
          currentDate = null;
          currentWhite = null;
          currentBlack = null;
          currentResult = null;
          moveLines.clear();
        } else if (trimmedLine.startsWith('[Date ')) {
          currentDate = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.startsWith('[White ')) {
          currentWhite = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.startsWith('[Black ')) {
          currentBlack = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.startsWith('[Result ')) {
          currentResult = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.isNotEmpty) {
          moveLines.add(trimmedLine);
        }
      }

      if (currentEvent != null && moveLines.isNotEmpty) {
        final game = _buildGame(currentEvent, currentDate, currentWhite, currentBlack, currentResult, moveLines);
        if (game != null) {
          processedGames.add(game);
        }
      }

      if (processedGames.isEmpty) {
        debugPrint('No games processed for tree building');
        _openingTree = OpeningTree();
        return;
      }

      _openingTree = await OpeningTreeBuilder.buildTree(
        pgnList: processedGames,
        username: '',
        userIsWhite: isWhiteRepertoire,
        maxDepth: 50,
        strictPlayerMatching: false,
      );

      debugPrint('Built opening tree with ${_openingTree?.totalGames} total games');
    } catch (e) {
      debugPrint('Failed to build opening tree: $e');
      _openingTree = OpeningTree();
    }
  }

  /// Syncs the game state from an external source (like the PGN editor).
  /// Use syncFromMoveIndex instead for move-based sync.
  void syncGameFromFen(String fen) {
    if (_position.fen == fen || _isInternalUpdate) {
      return;
    }
  }

  /// Sync to a specific move index from the PGN editor.
  void syncFromMoveIndex(int moveIndex, List<String> moves) {
    if (_isInternalUpdate) return;

    _moveHistory = List.from(moves);
    _currentMoveIndex = moveIndex;
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Handles position changes from the opening tree (current node path).
  void onTreePositionChanged(String fen) {
    if (_openingTree == null) return;

    final moves = _openingTree!.currentNode.getMovePath();

    _isInternalUpdate = true;
    _moveHistory = List.from(moves);
    _currentMoveIndex = moves.isEmpty ? -1 : moves.length - 1;
    _rebuildPosition();
    _isInternalUpdate = false;

    notifyListeners();
  }

  /// Loads a specific PGN line for editing.
  void loadPgnLine(RepertoireLine line) {
    _selectedPgnLine = line;

    _moveHistory = List.from(line.moves);
    _currentMoveIndex = line.moves.isEmpty ? -1 : line.moves.length - 1;
    _rebuildPosition();
    _syncOpeningTree();

    notifyListeners();
  }

  RepertoireLine? _selectedPgnLine;
  RepertoireLine? get selectedPgnLine => _selectedPgnLine;

  void clearSelectedPgnLine() {
    _selectedPgnLine = null;
    notifyListeners();
  }

  String? _extractHeaderValue(String line) =>
      pgn_utils.extractHeaderValue(line);

  String? _buildGame(
      String? event,
      String? date,
      String? white,
      String? black,
      String? result,
      List<String> moveLines,
      ) {
    if (moveLines.isEmpty) return null;

    final headers = <String>[];
    headers.add('[Event "${event ?? "Training Line"}"]');
    headers.add('[Date "${date ?? DateTime.now().toIso8601String().split('T')[0]}"]');
    headers.add('[White "${white ?? "Training"}"]');
    headers.add('[Black "${black ?? "Me"}"]');
    headers.add('[Result "${result ?? "1-0"}"]');

    final moves = moveLines.join(' ');
    return [...headers, '', moves].join('\n');
  }

  /// Append a newly saved line to the in-memory tree and lines list
  /// without reloading the entire repertoire from disk.
  void appendNewLine(List<String> moves, String title, String pgn) {
    _openingTree?.appendLine(moves);

    final index = _repertoireLines.length;
    final service = RepertoireService();
    final id = service.generateLineId(moves, index);
    final name = title.isNotEmpty && title != 'Repertoire Line'
        ? title
        : (moves.length >= 3
            ? 'Line: ${moves.take(3).join(' ')}'
            : 'Repertoire Line ${index + 1}');

    _repertoireLines.add(RepertoireLine(
      id: id,
      name: name,
      moves: moves,
      color: _isRepertoireWhite ? 'white' : 'black',
      startPosition: Chess.initial,
      fullPgn: pgn,
    ));

    notifyListeners();
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }
}
