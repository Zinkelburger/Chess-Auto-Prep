import 'package:flutter/material.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show buildMovetext;
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/core/pgn/pgn_variation_extractor.dart';

class PgnViewerWidgetController {
  _PgnViewerWidgetState? _state;

  void _attach(_PgnViewerWidgetState state) {
    _state = state;
  }

  void _detach(_PgnViewerWidgetState state) {
    if (_state == state) {
      _state = null;
    }
  }

  void goBack() {
    _state?._goBack();
  }

  void goForward() {
    _state?._goForward();
  }

  void addEphemeralMove(String san) {
    _state?._addAnalysisMove(san);
  }

  String? get currentFen => _state?._currentPosition.fen;

  void clearEphemeralMoves() {
    _state?._clearAnalysis();
  }

  void jumpToMove(int moveNumber, bool isWhiteToPlay) {
    final state = _state;
    if (state == null) return;
    state._clearAnalysis();
    state._jumpToMove(moveNumber, isWhiteToPlay);
  }

  /// Navigate directly to a mainline position by half-move index (0-based
  /// number of moves played from the start).
  void goToMainLineIndex(int moveIndex) {
    _state?._goToMainLineMove(moveIndex);
  }

  void deleteAnalysisNode(int nodeId) {
    _state?._deleteAnalysisNode(nodeId);
  }

  bool get hasAnalysis {
    final state = _state;
    if (state == null) return false;
    return state._variationsByPly.values.any((list) => list.isNotEmpty);
  }

  /// True when the user has added ephemeral analysis lines (not from PGN).
  bool get hasEphemeralMoves {
    final state = _state;
    if (state == null) return false;
    for (final roots in state._variationsByPly.values) {
      for (final root in roots) {
        if (state._subtreeHasEphemeral(root)) return true;
      }
    }
    return false;
  }

  int get mainLineIndex => _state?._mainLineIndex ?? 0;

  int get currentMainLineIndex => mainLineIndex;

  int get mainLineLength => _state?._moveHistory.length ?? 0;

  /// Number of moves deep into the current variation (0 if on mainline).
  int get variationDepth => _state?._analysisPath.length ?? 0;

  /// Toggle a NAG on a specific move (used by keyboard shortcuts).
  void toggleNagOnMove(int moveIndex, int nagId) {
    _state?._toggleNag(moveIndex, nagId);
  }
}

class PgnViewerWidget extends StatefulWidget {
  final String? gameId;
  final String? pgnText;
  final int? moveNumber;
  final bool? isWhiteToPlay;
  final Function(Position)? onPositionChanged;
  final PgnViewerWidgetController? controller;
  final String? initialFen;
  final bool showStartEndButtons;
  final Function(int nodeId, Offset globalPosition)? onAnalysisNodeAction;
  final ValueChanged<String>? onCommentsChanged;
  final bool editMode;
  final bool protectOriginal;

  const PgnViewerWidget({
    super.key,
    this.gameId,
    this.pgnText,
    this.moveNumber,
    this.isWhiteToPlay,
    this.onPositionChanged,
    this.controller,
    this.initialFen,
    this.showStartEndButtons = true,
    this.onAnalysisNodeAction,
    this.onCommentsChanged,
    this.editMode = false,
    this.protectOriginal = true,
  });

  @override
  State<PgnViewerWidget> createState() => _PgnViewerWidgetState();
}

class _PgnViewerWidgetState extends State<PgnViewerWidget>
    with AutomaticKeepAliveClientMixin {
  PgnGame? _game;
  List<PgnNodeData> _moveHistory = [];
  int _mainLineIndex = 0;
  Position _currentPosition = Chess.initial;
  Position _startPosition = Chess.initial;
  String _gameInfo = '';
  bool _isLoading = true;
  String? _error;

  // Variations: ply (0-based mainline index) -> list of root MoveNodes.
  // Supports multiple branch points simultaneously.
  Map<int, List<MoveNode>> _variationsByPly = {};
  int _activeBranchPly = -1; // which ply we're currently navigating in
  List<MoveNode> _analysisPath = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGame());
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    super.dispose();
  }

  static final _headerLineRe = RegExp(r'^\s*\[.*\]\s*$', multiLine: true);

  static String _stripHeaders(String pgn) =>
      pgn.replaceAll(_headerLineRe, '').trim();

  @override
  void didUpdateWidget(PgnViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final gameIdChanged = widget.gameId != oldWidget.gameId;
    final pgnChanged = widget.pgnText != oldWidget.pgnText;

    if (gameIdChanged ||
        (pgnChanged &&
            _stripHeaders(widget.pgnText ?? '') !=
                _stripHeaders(oldWidget.pgnText ?? ''))) {
      _loadGame();
    } else if (widget.moveNumber != oldWidget.moveNumber ||
        widget.isWhiteToPlay != oldWidget.isWhiteToPlay) {
      _clearAnalysis();
      if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
        _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
      }
    }
  }

  Future<void> _loadGame() async {
    if (widget.pgnText == null && widget.gameId == null) {
      setState(() {
        _error = 'No game ID or PGN text provided';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String pgnText;

      if (widget.pgnText != null) {
        pgnText = widget.pgnText!;
      } else {
        pgnText = await _findGamePgn(widget.gameId!);
        if (!mounted) return;
        if (pgnText.isEmpty) {
          setState(() {
            _error = 'Game not found in PGN files';
            _isLoading = false;
          });
          return;
        }
      }

      final game = PgnGame.parsePgn(pgnText);
      final moveHistory = game.moves.mainline().toList();
      if (!mounted) return;

      final startPos = startPositionFromGame(game);
      final pgnVariations = extractPgnVariations(game, startPos);

      setState(() {
        _game = game;
        _moveHistory = moveHistory;
        _mainLineIndex = 0;
        _startPosition = startPos;
        _currentPosition = startPos;
        _gameInfo = _buildGameInfo(game);
        _isLoading = false;
        _variationsByPly = pgnVariations;
        _activeBranchPly = -1;
        _analysisPath = [];
      });

      // Defer the position notification so it doesn't fire during
      // didUpdateWidget's build phase (which would cause setState-during-build).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onPositionChanged?.call(_currentPosition);
        if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
          _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
        } else if (widget.initialFen != null) {
          _jumpToFen(widget.initialFen!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error loading PGN: $e';
        _isLoading = false;
      });
    }
  }

  // ── Game search ──

  Future<String> _findGamePgn(String gameId) async {
    try {
      final content = await StorageFactory.instance.readImportedPgns();
      if (content == null || content.isEmpty) return '';
      final games = splitPgnIntoGames(content);
      for (final gameText in games) {
        if (gameText.contains('[GameId "$gameId"]')) return gameText;
      }
    } catch (e) {
      debugPrint('Error finding game PGN: $e');
    }
    return '';
  }

  String _buildGameInfo(PgnGame game) {
    final white = game.headers['White'] ?? '?';
    final black = game.headers['Black'] ?? '?';

    // Book-style PGN detection: Black is "?" and White is a chapter title
    final isBookChapter = black == '?' &&
        white != '?' &&
        (game.headers['Event'] == '?' || game.headers['Event'] == null);
    if (isBookChapter) {
      final annotator = game.headers['Annotator'];
      final parts = <String>[white];
      if (annotator != null && annotator.isNotEmpty) parts.add('by $annotator');
      return parts.join(' ');
    }

    final wElo = game.headers['WhiteElo'];
    final bElo = game.headers['BlackElo'];
    final wStr = wElo != null && wElo.isNotEmpty && wElo != '?'
        ? '$white ($wElo)'
        : white;
    final bStr = bElo != null && bElo.isNotEmpty && bElo != '?'
        ? '$black ($bElo)'
        : black;
    final event = game.headers['Event'] ?? '';
    final date = game.headers['Date'] ?? '';
    final result = game.headers['Result'] ?? '';
    return '$wStr vs $bStr\n$event • $date • $result';
  }

  // ── Navigation ──

  void _jumpToMove(int moveNumber, bool isWhiteToPlay) {
    if (_moveHistory.isEmpty) return;
    int targetPly = (moveNumber - 1) * 2;
    if (!isWhiteToPlay) targetPly += 1;
    targetPly = targetPly.clamp(0, _moveHistory.length);
    _goToMainLineMove(targetPly);
  }

  void _jumpToFen(String targetFen) {
    if (_moveHistory.isEmpty) return;
    final target = normalizeFen(targetFen);
    Position pos = _startPosition;
    for (int i = 0; i < _moveHistory.length; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
      if (normalizeFen(pos.fen) == target) {
        _goToMainLineMove(i + 1);
        return;
      }
    }
  }

  void _goToMainLineMove(int moveIndex) {
    if (moveIndex < 0 || moveIndex > _moveHistory.length) return;
    Position pos = _startPosition;
    for (int i = 0; i < moveIndex; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    setState(() {
      _mainLineIndex = moveIndex;
      _currentPosition = pos;
      _analysisPath = [];
      _activeBranchPly = -1;
    });
    widget.onPositionChanged?.call(pos);
  }

  void _goToAnalysisNode(MoveNode targetNode, int branchPly) {
    final roots = _variationsByPly[branchPly];
    if (roots == null) return;

    final path = _findPathToNode(targetNode, roots);
    if (path == null) return;

    Position pos = _startPosition;
    for (int i = 0; i < branchPly; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    for (final node in path) {
      if (node.san == '--') continue;
      final move = pos.parseSan(node.san);
      if (move == null) break;
      pos = pos.play(move);
    }

    setState(() {
      _mainLineIndex = branchPly;
      _activeBranchPly = branchPly;
      _currentPosition = pos;
      _analysisPath = path;
    });
    widget.onPositionChanged?.call(pos);
  }

  List<MoveNode>? _findPathToNode(
      MoveNode target, List<MoveNode> roots) {
    for (final root in roots) {
      final path = _findPathRecursive(root, target, []);
      if (path != null) return path;
    }
    return null;
  }

  List<MoveNode>? _findPathRecursive(
      MoveNode current, MoveNode target, List<MoveNode> pathSoFar) {
    final newPath = [...pathSoFar, current];
    if (current.id == target.id) return newPath;
    for (final child in current.children) {
      final result = _findPathRecursive(child, target, newPath);
      if (result != null) return result;
    }
    return null;
  }

  void _goToStart() {
    _goToMainLineMove(0);
  }

  void _goBack() {
    if (_analysisPath.isNotEmpty) {
      if (_analysisPath.length > 1) {
        final parentPath = _analysisPath.sublist(0, _analysisPath.length - 1);
        _goToAnalysisNode(parentPath.last, _activeBranchPly);
      } else {
        _goToMainLineMove(_activeBranchPly);
      }
    } else if (_mainLineIndex > 0) {
      _goToMainLineMove(_mainLineIndex - 1);
    }
  }

  void _goForward() {
    if (_analysisPath.isNotEmpty) {
      final current = _analysisPath.last;
      if (current.children.isNotEmpty) {
        _goToAnalysisNode(current.children.first, _activeBranchPly);
      }
    } else if (_mainLineIndex < _moveHistory.length) {
      _goToMainLineMove(_mainLineIndex + 1);
    }
  }

  void _goToEnd() {
    if (_analysisPath.isNotEmpty) {
      MoveNode current = _analysisPath.last;
      while (current.children.isNotEmpty) {
        current = current.children.first;
      }
      _goToAnalysisNode(current, _activeBranchPly);
    } else {
      _goToMainLineMove(_moveHistory.length);
    }
  }

  void _onMainLineMoveClicked(int moveIndex) {
    _goToMainLineMove(moveIndex + 1);
  }

  bool get _canGoBack {
    return _analysisPath.isNotEmpty || _mainLineIndex > 0;
  }

  bool get _canGoForward {
    if (_analysisPath.isNotEmpty && _analysisPath.last.children.isNotEmpty) {
      return true;
    }
    if (_analysisPath.isEmpty && _mainLineIndex < _moveHistory.length) {
      return true;
    }
    return false;
  }

  // ── Adding user moves ──

  void _addAnalysisMove(String san) {
    final parsedMove = _currentPosition.parseSan(san);
    if (parsedMove == null) return;

    Position newPos;
    try {
      newPos = _currentPosition.play(parsedMove);
    } catch (_) {
      return;
    }
    final fenAfter = newPos.fen;

    setState(() {
      if (_analysisPath.isEmpty) {
        // Starting new variation from mainline
        final ply = _mainLineIndex;
        final roots = _variationsByPly.putIfAbsent(ply, () => []);

        // Check if this move already exists
        MoveNode? existing;
        for (final root in roots) {
          if (root.san == san) {
            existing = root;
            break;
          }
        }

        if (existing != null) {
          _analysisPath = [existing];
        } else {
          final newNode =
              MoveNode(san: san, fen: fenAfter, isEphemeral: true);
          roots.add(newNode);
          _analysisPath = [newNode];
        }
        _activeBranchPly = ply;
      } else {
        // Extending current variation
        final current = _analysisPath.last;
        final (node, _) = current.addChild(san, fenAfter, isEphemeral: true);
        _analysisPath = [..._analysisPath, node];
      }
      _currentPosition = newPos;
    });
    widget.onPositionChanged?.call(newPos);
  }

  // ── Clear / delete ──

  void _clearAnalysis() {
    setState(() {
      // Remove only ephemeral nodes from all plies
      final keysToRemove = <int>[];
      for (final entry in _variationsByPly.entries) {
        entry.value.removeWhere((n) => n.isEphemeral);
        // Also remove ephemeral children from PGN nodes
        for (final root in entry.value) {
          _removeEphemeralChildren(root);
        }
        if (entry.value.isEmpty) keysToRemove.add(entry.key);
      }
      for (final k in keysToRemove) {
        _variationsByPly.remove(k);
      }
      _analysisPath = [];
      _activeBranchPly = -1;
    });
  }

  void _removeEphemeralChildren(MoveNode node) {
    node.children.removeWhere((c) => c.isEphemeral);
    for (final child in node.children) {
      _removeEphemeralChildren(child);
    }
  }

  bool _subtreeHasEphemeral(MoveNode node) {
    if (node.isEphemeral) return true;
    for (final child in node.children) {
      if (_subtreeHasEphemeral(child)) return true;
    }
    return false;
  }

  void _deleteAnalysisNode(int nodeId) {
    setState(() {
      for (final entry in _variationsByPly.entries) {
        final ply = entry.key;
        final roots = entry.value;

        final lengthBefore = roots.length;
        roots.removeWhere((n) => n.id == nodeId);
        if (roots.length < lengthBefore) {
          // If current path includes the deleted node, exit variation
          if (_activeBranchPly == ply && _analysisPath.isNotEmpty) {
            _analysisPath = [];
            _activeBranchPly = -1;
          }
          return;
        }

        // Search deeper
        for (final root in roots) {
          if (_removeNodeRecursive(root.children, nodeId)) {
            final idx = _analysisPath.indexWhere((n) => n.id == nodeId);
            if (idx != -1) {
              if (idx == 0) {
                _analysisPath = [];
                _activeBranchPly = -1;
              } else {
                _analysisPath = _analysisPath.sublist(0, idx);
                _goToAnalysisNode(_analysisPath.last, _activeBranchPly);
              }
            }
            return;
          }
        }
      }
    });
  }

  bool _removeNodeRecursive(List<MoveNode> nodes, int targetId) {
    for (final node in nodes) {
      if (node.children.any((c) => c.id == targetId)) {
        node.children.removeWhere((c) => c.id == targetId);
        return true;
      }
      if (_removeNodeRecursive(node.children, targetId)) return true;
    }
    return false;
  }

  // ── Move comment editing ──

  int? _editingCommentIndex;
  int? _selectedMoveIndex; // for annotation toolbar in edit mode

  void _startEditingComment(int moveIndex) {
    setState(() => _editingCommentIndex = moveIndex);
  }

  void _saveComment(int moveIndex, String newComment) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    final moveData = _moveHistory[moveIndex];
    final trimmed = newComment.trim();
    setState(() {
      if (trimmed.isEmpty) {
        moveData.comments?.clear();
      } else {
        if (moveData.comments == null || moveData.comments!.isEmpty) {
          moveData.comments = [trimmed];
        } else {
          moveData.comments![0] = trimmed;
        }
      }
      _editingCommentIndex = null;
    });
    _notifyCommentsChanged();
  }

  void _cancelEditingComment() {
    setState(() => _editingCommentIndex = null);
  }

  void _toggleNag(int moveIndex, int nagId) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    final moveData = _moveHistory[moveIndex];
    setState(() {
      final nags = moveData.nags ?? [];
      if (nags.contains(nagId)) {
        nags.remove(nagId);
      } else {
        // Remove other move-quality NAGs (1-6) before adding
        nags.removeWhere((n) => n >= 1 && n <= 6);
        nags.add(nagId);
      }
      moveData.nags = nags.isEmpty ? null : nags;
    });
    _notifyCommentsChanged();
  }

  void _selectMoveForAnnotation(int moveIndex) {
    setState(() {
      if (_selectedMoveIndex == moveIndex) {
        _selectedMoveIndex = null;
      } else {
        _selectedMoveIndex = moveIndex;
      }
    });
  }

  void _showMoveContextMenu(int moveIndex, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final protectOriginal = widget.protectOriginal;
    final hasBranch = _variationsByPly.containsKey(moveIndex + 1);

    showMenu<String>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'comment',
          child: Row(
            children: [
              Icon(Icons.comment_outlined, size: 18),
              SizedBox(width: 8),
              Text('Comment'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'annotate',
          child: Row(
            children: [
              Icon(Icons.edit_note, size: 18),
              SizedBox(width: 8),
              Text('Annotate'),
            ],
          ),
        ),
        if (hasBranch) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'promote',
            enabled: !protectOriginal,
            child: Row(
              children: [
                Icon(Icons.arrow_upward,
                    size: 18, color: protectOriginal ? Colors.grey[700] : null),
                const SizedBox(width: 8),
                Text('Promote variation',
                    style: protectOriginal
                        ? TextStyle(color: Colors.grey[700])
                        : null),
              ],
            ),
          ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          enabled: !protectOriginal,
          child: Row(
            children: [
              Icon(Icons.delete_outline,
                  size: 18,
                  color: protectOriginal ? Colors.grey[700] : Colors.red),
              const SizedBox(width: 8),
              Text('Delete move',
                  style: TextStyle(
                      color: protectOriginal ? Colors.grey[700] : Colors.red)),
            ],
          ),
        ),
      ],
    ).then((action) {
      if (action == 'comment') {
        _startEditingComment(moveIndex);
      } else if (action == 'annotate') {
        _selectMoveForAnnotation(moveIndex);
      }
      // promote and delete require tree manipulation (future)
    });
  }

  void _notifyCommentsChanged() {
    if (widget.onCommentsChanged == null || _moveHistory.isEmpty) return;
    final result = _game?.headers['Result'];
    widget.onCommentsChanged!(buildMovetext(_moveHistory, result: result));
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading game...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center),
          ],
        ),
      );
    }

    if (_game == null) {
      return const Center(child: Text('No game loaded'));
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          child: Text(_gameInfo,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: PgnMovetextView(
              game: _game,
              moveHistory: _moveHistory,
              variationsByPly: _variationsByPly,
              mainLineIndex: _mainLineIndex,
              analysisPath: _analysisPath,
              selectedMoveIndex: _selectedMoveIndex,
              editingCommentIndex: _editingCommentIndex,
              editMode: widget.editMode,
              canEditComments: widget.onCommentsChanged != null,
              onMainLineMoveClicked: _onMainLineMoveClicked,
              onSelectMoveForAnnotation: _selectMoveForAnnotation,
              onShowMoveContextMenu: _showMoveContextMenu,
              onStartEditingComment: _startEditingComment,
              onToggleNag: _toggleNag,
              onSaveComment: _saveComment,
              onCancelEditingComment: _cancelEditingComment,
              onDismissAnnotation: () =>
                  setState(() => _selectedMoveIndex = null),
              onGoToAnalysisNode: _goToAnalysisNode,
              onAnalysisNodeAction: widget.onAnalysisNodeAction,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (widget.showStartEndButtons)
                IconButton(
                    onPressed: _canGoBack ? _goToStart : null,
                    icon: const Icon(Icons.skip_previous),
                    tooltip: 'Start (Home)'),
              IconButton(
                  onPressed: _canGoBack ? _goBack : null,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Back (←)'),
              IconButton(
                  onPressed: _canGoForward ? _goForward : null,
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Forward (→)'),
              if (widget.showStartEndButtons)
                IconButton(
                    onPressed: _canGoForward ? _goToEnd : null,
                    icon: const Icon(Icons.skip_next),
                    tooltip: 'End (End)'),
            ],
          ),
        ),
      ],
    );
  }
}
