import 'package:flutter/material.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

/// A node in the analysis tree. Each node represents a move.
/// Children[0] is the main continuation, children[1+] are variations.
class AnalysisNode {
  final String san;
  final String fenAfter;
  final List<AnalysisNode> children;
  final int id;
  final bool isEphemeral; // true = user-added, false = from PGN

  static int _nextId = 0;

  AnalysisNode({
    required this.san,
    required this.fenAfter,
    this.isEphemeral = true,
  })  : children = [],
        id = _nextId++;

  AnalysisNode? findChild(String san) {
    for (final child in children) {
      if (child.san == san) return child;
    }
    return null;
  }

  (AnalysisNode node, bool isMainLine) addChild(String san, String fenAfter,
      {bool isEphemeral = true}) {
    final existing = findChild(san);
    if (existing != null) {
      return (existing, children.indexOf(existing) == 0);
    }
    final newNode =
        AnalysisNode(san: san, fenAfter: fenAfter, isEphemeral: isEphemeral);
    children.add(newNode);
    return (newNode, children.length == 1);
  }
}

class PgnViewerController {
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

  void deleteAnalysisNode(int nodeId) {
    _state?._deleteAnalysisNode(nodeId);
  }

  bool get hasAnalysis {
    final state = _state;
    if (state == null) return false;
    return state._variationsByPly.values.any((list) => list.isNotEmpty);
  }

  int get mainLineIndex => _state?._mainLineIndex ?? 0;

  int get mainLineLength => _state?._moveHistory.length ?? 0;
}

class PgnViewerWidget extends StatefulWidget {
  final String? gameId;
  final String? pgnText;
  final int? moveNumber;
  final bool? isWhiteToPlay;
  final Function(Position)? onPositionChanged;
  final PgnViewerController? controller;
  final String? initialFen;
  final bool showStartEndButtons;
  final Function(int nodeId, Offset globalPosition)? onAnalysisNodeAction;
  final ValueChanged<String>? onCommentsChanged;

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
  String _gameInfo = '';
  bool _isLoading = true;
  String? _error;

  // Variations: ply (0-based mainline index) -> list of root AnalysisNodes.
  // Supports multiple branch points simultaneously.
  Map<int, List<AnalysisNode>> _variationsByPly = {};
  int _activeBranchPly = -1; // which ply we're currently navigating in
  List<AnalysisNode> _analysisPath = [];

  final List<TapGestureRecognizer> _gestureRecognizers = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _loadGame();
  }

  @override
  void dispose() {
    for (final r in _gestureRecognizers) {
      r.dispose();
    }
    _gestureRecognizers.clear();
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

      final pgnVariations = _extractPgnVariations(game);

      setState(() {
        _game = game;
        _moveHistory = moveHistory;
        _mainLineIndex = 0;
        _currentPosition = Chess.initial;
        _gameInfo = _buildGameInfo(game);
        _isLoading = false;
        _variationsByPly = pgnVariations;
        _activeBranchPly = -1;
        _analysisPath = [];
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
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

  // ── PGN variation extraction ──

  /// Walk the parsed PGN tree and extract sideline variations at each ply.
  Map<int, List<AnalysisNode>> _extractPgnVariations(PgnGame game) {
    final result = <int, List<AnalysisNode>>{};

    // Walk the mainline using the PgnNode tree (not the flattened list)
    // to find sideline children at each node.
    PgnNode<PgnNodeData> node = game.moves;
    Position pos = Chess.initial;
    int ply = 0;

    while (node.children.isNotEmpty) {
      final mainChild = node.children[0];

      // Sideline variations at this ply (children[1+])
      if (node.children.length > 1) {
        final variations = <AnalysisNode>[];
        for (int i = 1; i < node.children.length; i++) {
          final sidelineRoot = node.children[i];
          final converted = _convertPgnSubtree(sidelineRoot, pos);
          if (converted != null) variations.add(converted);
        }
        if (variations.isNotEmpty) {
          result[ply] = variations;
        }
      }

      // Advance position along mainline
      final move = pos.parseSan(mainChild.data.san);
      if (move == null) break;
      pos = pos.play(move);
      ply++;
      node = mainChild;
    }

    return result;
  }

  /// Recursively convert a PgnChildNode subtree into an AnalysisNode tree.
  AnalysisNode? _convertPgnSubtree(
      PgnChildNode<PgnNodeData> pgnNode, Position posBeforeMove) {
    final move = posBeforeMove.parseSan(pgnNode.data.san);
    if (move == null) return null;

    Position posAfter;
    try {
      posAfter = posBeforeMove.play(move);
    } catch (_) {
      return null;
    }

    final node = AnalysisNode(
      san: pgnNode.data.san,
      fenAfter: posAfter.fen,
      isEphemeral: false,
    );

    // Convert children: children[0] is main continuation, [1+] are sub-variations
    for (int i = 0; i < pgnNode.children.length; i++) {
      final childNode = _convertPgnSubtree(pgnNode.children[i], posAfter);
      if (childNode != null) node.children.add(childNode);
    }

    return node;
  }

  // ── Game search ──

  Future<String> _findGamePgn(String gameId) async {
    try {
      final content = await StorageFactory.instance.readImportedPgns();
      if (content == null || content.isEmpty) return '';
      final games = _splitPgnIntoGames(content);
      for (final gameText in games) {
        if (gameText.contains('[GameId "$gameId"]')) return gameText;
      }
    } catch (e) {
      debugPrint('Error finding game PGN: $e');
    }
    return '';
  }

  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');
    String currentGame = '';
    bool inGame = false;
    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.isNotEmpty) games.add(currentGame);
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      }
    }
    if (inGame && currentGame.isNotEmpty) games.add(currentGame);
    return games;
  }

  String _buildGameInfo(PgnGame game) {
    final white = game.headers['White'] ?? '?';
    final black = game.headers['Black'] ?? '?';
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
    Position pos = Chess.initial;
    for (int i = 0; i < _moveHistory.length; i++) {
      final move = pos.parseSan(_moveHistory[i].san);
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
    Position pos = Chess.initial;
    for (int i = 0; i < moveIndex; i++) {
      final move = pos.parseSan(_moveHistory[i].san);
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

  void _goToAnalysisNode(AnalysisNode targetNode, int branchPly) {
    final roots = _variationsByPly[branchPly];
    if (roots == null) return;

    final path = _findPathToNode(targetNode, roots);
    if (path == null) return;

    Position pos = Chess.initial;
    for (int i = 0; i < branchPly; i++) {
      final move = pos.parseSan(_moveHistory[i].san);
      if (move == null) break;
      pos = pos.play(move);
    }
    for (final node in path) {
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

  List<AnalysisNode>? _findPathToNode(
      AnalysisNode target, List<AnalysisNode> roots) {
    for (final root in roots) {
      final path = _findPathRecursive(root, target, []);
      if (path != null) return path;
    }
    return null;
  }

  List<AnalysisNode>? _findPathRecursive(
      AnalysisNode current, AnalysisNode target, List<AnalysisNode> pathSoFar) {
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
      AnalysisNode current = _analysisPath.last;
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
        AnalysisNode? existing;
        for (final root in roots) {
          if (root.san == san) {
            existing = root;
            break;
          }
        }

        if (existing != null) {
          _analysisPath = [existing];
        } else {
          final newNode = AnalysisNode(
              san: san, fenAfter: fenAfter, isEphemeral: true);
          roots.add(newNode);
          _analysisPath = [newNode];
        }
        _activeBranchPly = ply;
      } else {
        // Extending current variation
        final current = _analysisPath.last;
        final (node, _) =
            current.addChild(san, fenAfter, isEphemeral: true);
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

  void _removeEphemeralChildren(AnalysisNode node) {
    node.children.removeWhere((c) => c.isEphemeral);
    for (final child in node.children) {
      _removeEphemeralChildren(child);
    }
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

  bool _removeNodeRecursive(List<AnalysisNode> nodes, int targetId) {
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

  void _notifyCommentsChanged() {
    if (widget.onCommentsChanged == null || _moveHistory.isEmpty) return;
    final buf = StringBuffer();
    var moveNum = 1;
    var isWhite = true;
    for (final move in _moveHistory) {
      if (isWhite) buf.write('$moveNum. ');
      buf.write('${move.san} ');
      if (move.comments != null && move.comments!.isNotEmpty) {
        for (final c in move.comments!) {
          if (c.isNotEmpty) buf.write('{$c} ');
        }
      }
      if (!isWhite) moveNum++;
      isWhite = !isWhite;
    }
    final result = _game?.headers['Result'];
    if (result != null && result != '*') buf.write(result);
    widget.onCommentsChanged!(buf.toString().trim());
  }

  // ── Comment filtering ──

  static final _evalRe = RegExp(r'\[%eval [^\]]+\]');
  static final _clkRe = RegExp(r'\[%clk [^\]]+\]');
  static final _maiaRe = RegExp(r'\[%maia [^\]]+\]');
  static final _pvRe = RegExp(r'\[%pv [^\]]+\]');
  static final _scoreArrowRe =
      RegExp(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)');
  static final _classificationRe = RegExp(
      r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.');
  static final _wasBestRe = RegExp(r'[A-Za-z0-9+#-]+\s+was best\.?');
  static final _whitespaceRe = RegExp(r'\s+');

  String _filterComment(String comment) {
    comment = comment.replaceAll(_evalRe, '');
    comment = comment.replaceAll(_clkRe, '');
    comment = comment.replaceAll(_maiaRe, '');
    comment = comment.replaceAll(_pvRe, '');
    comment = comment.replaceAll(_scoreArrowRe, '');
    comment = comment.replaceAll(_classificationRe, '');
    comment = comment.replaceAll(_wasBestRe, '');
    comment = comment.replaceAll(_whitespaceRe, ' ').trim();
    if (comment.isEmpty || comment == '.,;!?') return '';
    return comment;
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
            child: _buildPgnDisplay(),
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

  TapGestureRecognizer _createTapRecognizer(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _gestureRecognizers.add(r);
    return r;
  }

  String _rawComment(PgnNodeData moveData) {
    if (moveData.comments == null || moveData.comments!.isEmpty) return '';
    return moveData.comments!.first;
  }

  Widget _buildPgnDisplay() {
    if (_moveHistory.isEmpty && _variationsByPly.isEmpty) {
      return const SizedBox();
    }

    for (final r in _gestureRecognizers) {
      r.dispose();
    }
    _gestureRecognizers.clear();

    final children = <Widget>[];
    final spans = <InlineSpan>[];
    var moveNumber = 1;
    var isWhiteTurn = true;

    final baseStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 14,
      color: Colors.grey[300],
    );

    void flushSpans() {
      if (spans.isNotEmpty) {
        children.add(RichText(
          text: TextSpan(style: baseStyle, children: List.of(spans)),
        ));
        spans.clear();
      }
    }

    // Variations at ply 0 (before any move)
    final varsAtZero = _variationsByPly[0];
    if (varsAtZero != null && varsAtZero.isNotEmpty) {
      spans.addAll(_buildVariationSpansAtPly(0));
    }

    for (int i = 0; i < _moveHistory.length; i++) {
      final moveData = _moveHistory[i];
      final san = moveData.san;

      if (isWhiteTurn) {
        spans.add(TextSpan(
          text: '$moveNumber. ',
          style:
              TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600]),
        ));
      }

      final isCurrentMove = i == _mainLineIndex - 1 && _analysisPath.isEmpty;
      final hasBranch = _variationsByPly.containsKey(i + 1);

      final canEditComments = widget.onCommentsChanged != null;

      if (canEditComments) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () => _onMainLineMoveClicked(i),
              onLongPressStart: (_) => _startEditingComment(i),
              onSecondaryTapDown: (_) => _startEditingComment(i),
              child: Text(
                san,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  color: isCurrentMove
                      ? Colors.white
                      : (hasBranch ? Colors.blue[200] : Colors.blue[300]),
                  fontWeight: (isCurrentMove || hasBranch)
                      ? FontWeight.bold
                      : FontWeight.normal,
                  backgroundColor: isCurrentMove ? Colors.blue[700] : null,
                ),
              ),
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: san,
            style: TextStyle(
              color: isCurrentMove
                  ? Colors.white
                  : (hasBranch ? Colors.blue[200] : Colors.blue[300]),
              fontWeight: (isCurrentMove || hasBranch)
                  ? FontWeight.bold
                  : FontWeight.normal,
              backgroundColor: isCurrentMove ? Colors.blue[700] : null,
            ),
            recognizer: _createTapRecognizer(() => _onMainLineMoveClicked(i)),
          ),
        );
      }

      spans.add(const TextSpan(text: ' '));

      // Inline comment editor
      if (_editingCommentIndex == i) {
        flushSpans();
        children.add(_CommentEditor(
          initialText: _rawComment(moveData),
          onSave: (text) => _saveComment(i, text),
          onCancel: _cancelEditingComment,
        ));
      } else if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        final comment = _filterComment(moveData.comments!.first);
        if (comment.isNotEmpty) {
          if (canEditComments) {
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () => _startEditingComment(i),
                  child: Text(
                    '{$comment} ',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      color: Colors.green,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            );
          } else {
            spans.add(TextSpan(
              text: '{$comment} ',
              style: const TextStyle(
                  color: Colors.green, fontStyle: FontStyle.italic),
            ));
          }
        }
      }

      // Render variations at this ply (ply = i+1 because variations branch
      // *after* the move at index i has been played)
      final ply = i + 1;
      final varsHere = _variationsByPly[ply];
      if (varsHere != null && varsHere.isNotEmpty) {
        spans.addAll(_buildVariationSpansAtPly(ply));
      }

      if (!isWhiteTurn) moveNumber++;
      isWhiteTurn = !isWhiteTurn;
    }

    // Variations after last move
    final endPly = _moveHistory.length;
    final varsAtEnd = _variationsByPly[endPly];
    if (varsAtEnd != null && varsAtEnd.isNotEmpty) {
      spans.addAll(_buildVariationSpansAtPly(endPly));
    }

    flushSpans();

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  /// Build variation spans for all roots at a given ply.
  List<InlineSpan> _buildVariationSpansAtPly(int ply) {
    final roots = _variationsByPly[ply];
    if (roots == null || roots.isEmpty) return const [];

    final spans = <InlineSpan>[];
    final moveNum = (ply ~/ 2) + 1;
    final isWhiteTurn = ply % 2 == 0;

    for (final root in roots) {
      final bracketColor =
          root.isEphemeral ? Colors.orange[300]! : Colors.teal[200]!;

      spans.add(TextSpan(
        text: '( ',
        style: TextStyle(color: bracketColor, fontWeight: FontWeight.bold),
      ));

      spans.addAll(_buildNodeSpans(root, moveNum, isWhiteTurn, true, ply));

      spans.add(TextSpan(
        text: ') ',
        style: TextStyle(color: bracketColor, fontWeight: FontWeight.bold),
      ));
    }

    return spans;
  }

  /// Recursively build spans for a node and its children.
  List<InlineSpan> _buildNodeSpans(AnalysisNode node, int moveNumber,
      bool isWhiteTurn, bool isFirst, int branchPly) {
    final spans = <InlineSpan>[];
    final moveColor =
        node.isEphemeral ? Colors.orange[300]! : Colors.teal[300]!;
    final numColor =
        node.isEphemeral ? Colors.orange[200]! : Colors.teal[200]!;

    if (isWhiteTurn) {
      spans.add(TextSpan(
        text: '$moveNumber. ',
        style: TextStyle(color: numColor, fontWeight: FontWeight.bold),
      ));
    } else if (isFirst) {
      spans.add(TextSpan(
        text: '$moveNumber... ',
        style: TextStyle(color: numColor, fontWeight: FontWeight.bold),
      ));
    }

    final isCurrentNode =
        _analysisPath.isNotEmpty && _analysisPath.last.id == node.id;

    if (widget.onAnalysisNodeAction != null && node.isEphemeral) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () => _goToAnalysisNode(node, branchPly),
            onSecondaryTapDown: (details) =>
                widget.onAnalysisNodeAction!(node.id, details.globalPosition),
            onLongPressStart: (details) =>
                widget.onAnalysisNodeAction!(node.id, details.globalPosition),
            child: Text(
              node.san,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: isCurrentNode ? Colors.white : moveColor,
                fontWeight:
                    isCurrentNode ? FontWeight.bold : FontWeight.normal,
                backgroundColor: isCurrentNode
                    ? (node.isEphemeral
                        ? Colors.orange[700]
                        : Colors.teal[700])
                    : null,
              ),
            ),
          ),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: node.san,
          style: TextStyle(
            color: isCurrentNode ? Colors.white : moveColor,
            fontWeight: isCurrentNode ? FontWeight.bold : FontWeight.normal,
            backgroundColor: isCurrentNode
                ? (node.isEphemeral ? Colors.orange[700] : Colors.teal[700])
                : null,
          ),
          recognizer: _createTapRecognizer(
              () => _goToAnalysisNode(node, branchPly)),
        ),
      );
    }

    spans.add(const TextSpan(text: ' '));

    final nextMoveNumber = isWhiteTurn ? moveNumber : moveNumber + 1;
    final nextIsWhite = !isWhiteTurn;

    if (node.children.isNotEmpty) {
      spans.addAll(_buildNodeSpans(
          node.children.first, nextMoveNumber, nextIsWhite, false, branchPly));

      for (int i = 1; i < node.children.length; i++) {
        final variation = node.children[i];
        final subColor =
            variation.isEphemeral ? Colors.amber[400]! : Colors.teal[200]!;

        spans.add(TextSpan(
          text: '( ',
          style: TextStyle(color: subColor, fontWeight: FontWeight.bold),
        ));
        spans.addAll(_buildNodeSpans(
            variation, nextMoveNumber, nextIsWhite, true, branchPly));
        spans.add(TextSpan(
          text: ') ',
          style: TextStyle(color: subColor, fontWeight: FontWeight.bold),
        ));
      }
    }

    return spans;
  }
}

// ---------------------------------------------------------------------------
// Inline comment editor widget
// ---------------------------------------------------------------------------
class _CommentEditor extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  const _CommentEditor({
    required this.initialText,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_CommentEditor> createState() => _CommentEditorState();
}

class _CommentEditorState extends State<_CommentEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.comment, size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: null,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.green,
                fontStyle: FontStyle.italic,
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                border: InputBorder.none,
                hintText: 'Add comment...',
                hintStyle: TextStyle(color: Colors.green, fontSize: 13),
              ),
              onSubmitted: (v) => widget.onSave(v),
            ),
          ),
          IconButton(
            onPressed: () => widget.onSave(_controller.text),
            icon: const Icon(Icons.check, size: 18, color: Colors.green),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          IconButton(
            onPressed: widget.onCancel,
            icon: Icon(Icons.close, size: 18, color: Colors.grey[500]),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}
