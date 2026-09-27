/// The PGN viewer's game state — the parsed game, its flat mainline spine,
/// the per-ply sideline trees, and the navigation cursor — the collaborator
/// every consumer leans on (solitaire, the viewer screen, the tactics panes).
///
/// The widget keeps rendering-only state (inline comment-line previews,
/// context menus, comment editors) and wraps each mutation here in its own
/// `setState`/notification; methods that move the cursor return `true` when
/// they acted so the caller knows whether to notify.
///
/// Tree walks over the sidelines live in `sideline_tree.dart`; the
/// conversion back to PGN in `viewer_game_serializer.dart`.
library;

import '../models/solitaire_script.dart' show SolitaireGameView;

import 'package:dartchess/dartchess.dart';
import 'viewer_sideline_adoption.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_game_copy.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_game_view.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_view.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/chess_core/pgn/sideline_projection_cache.dart';
import 'package:chess_auto_prep/chess_core/analysis/game_eval_annotations.dart'
    show annotateGameMoveQuality;
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart'
    show startPositionFromGame;
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show buildGameMovetext, joinComments;
import 'package:chess_auto_prep/chess_core/pgn/quality_nags.dart';
import 'package:chess_auto_prep/chess_core/pgn/mainline_positions.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_analysis_variations.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_dummy_mainline.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_variation_extractor.dart';
import 'package:chess_auto_prep/chess_core/moves/sideline_tree.dart';
import 'package:chess_auto_prep/features/documents/models/solitaire_reveal.dart';
import 'package:chess_auto_prep/chess_core/pgn/viewer_game_serializer.dart'
    as serializer;

/// What [ViewerGameController.addMove] did with the move.
enum ViewerMoveKind {
  /// Not legal at the current position.
  illegal,

  /// Appended to the end of the mainline (amend mode) — persist.
  extendedMainline,

  /// The game's own next move: the cursor advanced, nothing was added.
  followedMainline,

  /// Entered (or extended) a sideline variation — persist when editing.
  variation,
}

class ViewerGameController implements SolitaireGameView {
  Position get startPosition => _startPosition;
  Position get currentPosition => _currentPosition;
  int get mainLineIndex => _mainLineIndex;
  int get activeBranchPly => _activeBranchPly;
  bool get didMaterializeAnalysis => _didMaterializeAnalysis;

  PgnGame? _game;
  PgnGameMetadata? _metadata;
  PgnGameMetadata? get game => _metadata;
  Object _session = Object();
  Object get session => _session;

  List<PgnMoveSnapshot>? _moveView;
  final _moveSnapshots = <PgnNodeData, PgnMoveSnapshot>{};
  Expando<Object> _moveIdentities = Expando('Viewer move identities');

  @override
  List<PgnMoveSnapshot> get moveHistory =>
      _moveView ??= List.unmodifiable(_moveHistory.map(_snapshotOf));

  PgnMoveSnapshot _snapshotOf(PgnNodeData move) => _moveSnapshots.putIfAbsent(
    move,
    () => PgnMoveSnapshot.capture(
      move,
      identity: _moveIdentities[move] ??= Object(),
    ),
  );

  void _mainlineChanged([PgnNodeData? move]) {
    _moveView = null;
    if (move == null) {
      _moveSnapshots.clear();
    } else {
      _moveSnapshots.remove(move);
    }
  }

  bool _matchesMove(int index, Object? expectedMove) =>
      index >= 0 &&
      index < _moveHistory.length &&
      (expectedMove == null ||
          identical(_moveIdentities[_moveHistory[index]], expectedMove));

  /// Whether the last load/adoption converted legacy PVs to stored variations.
  bool _didMaterializeAnalysis = false;
  List<PgnNodeData> _moveHistory = [];
  Position _startPosition = Chess.initial;
  Position _currentPosition = Chess.initial;

  /// Sidelines: ply (0-based mainline index of the branch point) → roots.
  SidelineForest _variationsByPly = {};
  final _sidelineViews = SidelineProjectionCache();

  @override
  Map<int, List<MoveNodeSnapshot>> get variationsByPly =>
      _sidelineViews.read(_variationsByPly);

  List<MoveNodeSnapshot>? _pathView;
  List<MoveNode>? _pathSource;
  Map<int, List<MoveNodeSnapshot>>? _pathForest;
  List<MoveNodeSnapshot> get analysisPath {
    final forest = variationsByPly;
    if (identical(_pathSource, _analysisPath) &&
        identical(_pathForest, forest)) {
      return _pathView!;
    }
    var candidates = forest[_activeBranchPly] ?? const <MoveNodeSnapshot>[];
    final path = <MoveNodeSnapshot>[];
    for (final owned in _analysisPath) {
      final snapshot = candidates.firstWhere((node) => node.id == owned.id);
      path.add(snapshot);
      candidates = snapshot.children;
    }
    _pathSource = _analysisPath;
    _pathForest = forest;
    return _pathView = List.unmodifiable(path);
  }

  /// The mutable objects are resolved inside the owner, never from a caller.
  (int, List<MoveNode>)? _locate(int id, {int? branchPly}) {
    for (final entry in _variationsByPly.entries) {
      if (branchPly != null && entry.key != branchPly) continue;
      for (final root in entry.value) {
        final path = root.pathToId(id);
        if (path != null) return (entry.key, path.cast<MoveNode>());
      }
    }
    return null;
  }

  void _markPath(int ply, List<MoveNode> path) =>
      _sidelineViews.changed(ply, ancestry: path.map((node) => node.id));

  bool _promotePath(int ply, List<MoveNode> path) {
    if (!path.any((node) => node.isEphemeral)) return false;
    _markPath(ply, path);
    for (final node in path) {
      node.isEphemeral = false;
    }
    return true;
  }

  int _mainLineIndex = 0;

  /// Mainline ply of the sideline the cursor is in; -1 on the mainline.
  int _activeBranchPly = -1;

  /// Root-first sideline nodes from the branch point to the cursor; empty
  /// on the mainline.
  List<MoveNode> _analysisPath = [];

  /// What a running solitaire session lets the reader see: mainline
  /// navigation never walks past its frontier ply, and sidelines it has not
  /// reached cannot be entered. Null when no session is running.
  SolitaireReveal? _reveal;
  SolitaireReveal? get reveal => _reveal;
  set reveal(SolitaireReveal? value) {
    _reveal = value == null
        ? null
        : SolitaireReveal(
            mainlinePly: value.mainlinePly,
            nodeIds: Set.unmodifiable(value.nodeIds),
            hidesUnreachedSidelines: value.hidesUnreachedSidelines,
          );
  }

  /// Solitaire mainline frontier, or null when no session is running.
  int? get revealedPly => reveal?.mainlinePly;

  /// Whether a sideline node may be shown or entered right now.
  bool isNodeVisible(MoveNodeView node, int branchPly) =>
      reveal?.isNodeVisible(node, branchPly) ?? true;

  bool get hasAnalysis => _variationsByPly.values.any((l) => l.isNotEmpty);

  bool get hasEphemeralMoves => _variationsByPly.hasEphemeral;

  /// The board after each mainline ply, computed once and extended as the
  /// mainline grows.  Every navigation reads from here instead of replaying
  /// the game from the start.
  @override
  MainlinePositions get mainline =>
      MainlinePositions.of(_moveHistory, _startPosition);

  // ── Load ─────────────────────────────────────────────────────────────

  /// Adopt a freshly parsed game: mainline spine, start position, and the
  /// PGN's own sidelines. Resets the cursor to the start.
  void load(PgnGame parsed) {
    parsed = copyParsedPgn(parsed);
    _session = Object();
    _mainlineChanged();
    _moveIdentities = Expando('Viewer move identities');
    promoteNullMoveDummyMainline(parsed.moves);
    _didMaterializeAnalysis = annotateGameMoveQuality(parsed);
    _game = parsed;
    _metadata = PgnGameMetadata.capture(parsed);
    _moveHistory = parsed.moves.mainline().toList();
    _startPosition = startPositionFromGame(parsed);
    _currentPosition = _startPosition;
    _variationsByPly = extractPgnVariations(parsed, _startPosition);
    _sidelineViews.reset();
    _mainLineIndex = 0;
    _leaveSideline();
  }

  /// Take annotations onto the matching stored tree while preserving node
  /// identities, the cursor and scratch continuations. Incoming comments,
  /// introductions, glyphs and sibling order apply throughout the tree.
  ///
  /// This is what an engine pass hands back: the same moves, now with
  /// `[%eval]`/`[%pv]` comments on them. Reloading for that would park the
  /// reader back at move one (and restart a solitaire game), so the model
  /// adopts the new comments in place instead. Returns false when [parsed]
  /// is not the same game — a different mainline, or a different set of
  /// stored sidelines — in which case the caller must reload.
  bool adoptAnnotations(PgnGame parsed) {
    parsed = copyParsedPgn(parsed);
    if (startPositionFromGame(parsed).fen != _startPosition.fen) return false;
    promoteNullMoveDummyMainline(parsed.moves);
    final materialized = annotateGameMoveQuality(parsed);
    final incoming = parsed.moves.mainline().toList();
    if (!_sameMainline(incoming)) return false;
    final storedRoots = extractPgnVariations(parsed, _startPosition);
    final adoption = ViewerSidelineAdoption.plan(
      current: _variationsByPly,
      incoming: storedRoots,
      enginePaths: {
        for (var ply = 0; ply < incoming.length; ply++)
          ply: analysisVariationPath(incoming[ply]),
      },
    );
    if (adoption == null) return false;
    for (final MapEntry(key: ply, value: dirty)
        in adoption.apply(_variationsByPly).entries) {
      _sidelineViews.changed(ply, ancestry: dirty);
    }
    _didMaterializeAnalysis = materialized;
    _mainlineChanged();
    _game = parsed;
    _metadata = PgnGameMetadata.capture(parsed);
    for (var i = 0; i < incoming.length; i++) {
      _moveHistory[i]
        ..comments = incoming[i].comments
        ..startingComments = incoming[i].startingComments
        ..nags = incoming[i].nags;
    }
    return true;
  }

  bool _sameMainline(List<PgnNodeData> incoming) {
    if (incoming.length != _moveHistory.length) return false;
    for (var i = 0; i < incoming.length; i++) {
      if (incoming[i].san != _moveHistory[i].san) return false;
    }
    return true;
  }

  // ── Navigation ───────────────────────────────────────────────────────

  /// Park the cursor after [moveIndex] mainline half-moves (clamped to the
  /// solitaire frontier). Returns false when the index is out of range.
  bool goToMainLineMove(int moveIndex) {
    final frontier = revealedPly;
    if (frontier != null && moveIndex > frontier) moveIndex = frontier;
    if (moveIndex < 0 || moveIndex > _moveHistory.length) return false;
    _mainLineIndex = moveIndex;
    _currentPosition = mainline.at(moveIndex);
    _leaveSideline();
    return true;
  }

  /// Mainline index whose position matches [targetFen], or null when the
  /// game never reaches it. Index 0 is the start position.
  int? mainlineIndexOfFen(String targetFen) =>
      mainline.indexOfFen(normalizeFen(targetFen));

  /// Move the cursor onto [targetNode] inside the sidelines rooted at
  /// [branchPly]. Returns false when the node can't be located.
  bool goToAnalysisNode(MoveNodeView targetNode, int branchPly) {
    final location = _locate(targetNode.id, branchPly: branchPly);
    if (location == null) return false;
    final (_, path) = location;
    if (!isNodeVisible(path.last, branchPly)) return false;

    _mainLineIndex = branchPly;
    _activeBranchPly = branchPly;
    // Every sideline node carries the board after its move, so the target
    // is one lookup rather than a replay of the branch prefix and the path.
    _currentPosition = path.isEmpty
        ? mainline.at(branchPly)
        : path.last.position;
    _analysisPath = path;
    return true;
  }

  /// Inline comment-line preview: the widget steps the board through a
  /// comment's move run without touching the trees; the model just records
  /// the anchored mainline index and the preview board.
  void setInlinePreviewPosition(int baseIndex, Position pos) {
    _mainLineIndex = baseIndex;
    _leaveSideline();
    _currentPosition = pos;
  }

  /// Give a comment/PV preview normal ancestry before a user edits it.
  /// Reuse existing moves and keep the unplayed continuation as scratch nodes.
  /// Merely viewing a preview does not call this or change the saved PGN.
  /// Returns false if the preview cannot be reached from this mainline anchor
  /// (for example, a separate diagram embedded in a comment).
  bool materializePreviewLine(int baseIndex, List<String> sans, int cursor) {
    if (cursor <= 0 || cursor > sans.length) return false;
    final previewed = _replay(mainline.tryAt(baseIndex), sans.take(cursor));
    if (previewed == null) return false;
    if (normalizeFen(previewed.fen) != normalizeFen(_currentPosition.fen)) {
      return false;
    }
    final frontier = revealedPly;
    if (frontier != null && baseIndex > frontier) return false;

    goToMainLineMove(baseIndex);
    var selected = _cursor;
    for (var i = 0; i < sans.length; i++) {
      if (addMove(sans[i], editing: false, allowMainline: true) ==
          ViewerMoveKind.illegal) {
        break;
      }
      if (i + 1 == cursor) selected = _cursor;
    }
    _cursor = selected;
    return true;
  }

  /// The board after playing [sans] from [start]; null when [start] is
  /// missing or any move fails to play.
  static Position? _replay(Position? start, Iterable<String> sans) {
    var pos = start;
    for (final san in sans) {
      if (pos == null) return null;
      pos = _tryPlay(pos, san);
    }
    return pos;
  }

  /// The four cursor fields as one value, so a navigation can be snapshotted
  /// and restored without listing them twice.
  _Cursor get _cursor => (
    mainLineIndex: _mainLineIndex,
    activeBranchPly: _activeBranchPly,
    analysisPath: List.of(_analysisPath),
    position: _currentPosition,
  );

  set _cursor(_Cursor value) {
    _mainLineIndex = value.mainLineIndex;
    _activeBranchPly = value.activeBranchPly;
    _analysisPath = value.analysisPath;
    _currentPosition = value.position;
  }

  /// Put the cursor back on the mainline at [_mainLineIndex].
  void _leaveSideline() {
    _analysisPath = [];
    _activeBranchPly = -1;
  }

  // ── Adding moves ─────────────────────────────────────────────────────

  /// Play [san] at the cursor. [editing] marks additions permanent (amend
  /// mode); [allowMainline] controls following or extending the mainline.
  /// An inline preview must first acquire ancestry via [materializePreviewLine].
  ViewerMoveKind addMove(
    String san, {
    required bool editing,
    required bool allowMainline,
  }) {
    final newPos = _tryPlay(_currentPosition, san);
    if (newPos == null) return ViewerMoveKind.illegal;
    final onMainline = _analysisPath.isEmpty && allowMainline;

    // Amend mode at the end of the mainline: extend it rather than fork.
    if (editing && onMainline && _mainLineIndex == _moveHistory.length) {
      final added = PgnNodeData(san: san);
      _moveHistory.add(added);
      _mainlineChanged(added);
      _mainLineIndex = _moveHistory.length;
      _currentPosition = newPos;
      return ViewerMoveKind.extendedMainline;
    }

    // The game's own next move: follow it instead of duplicating it as a
    // sideline beside itself.
    if (onMainline &&
        _mainLineIndex < _moveHistory.length &&
        _moveHistory[_mainLineIndex].san == san) {
      _mainLineIndex++;
      _currentPosition = newPos;
      return ViewerMoveKind.followedMainline;
    }

    if (_analysisPath.isEmpty) {
      final ply = _mainLineIndex;
      final roots = _variationsByPly.putIfAbsent(ply, () => []);
      var root = _siblingWithSan(roots, san);
      if (root == null) {
        root = MoveNode(
          san: san,
          fen: newPos.fen,
          position: newPos,
          isEphemeral: !editing,
        );
        _sidelineViews.changed(ply, ancestry: const []);
        roots.add(root);
      }
      _analysisPath = [root];
      _activeBranchPly = ply;
    } else {
      final parent = _analysisPath.last;
      final previousCount = parent.children.length;
      final (node, _) = parent.addChild(san, newPos.fen, isEphemeral: !editing);
      if (parent.children.length != previousCount) {
        _markPath(_activeBranchPly, _analysisPath);
      }
      _analysisPath = [..._analysisPath, node];
    }
    // Include an existing scratch node when the user plays it in an editable
    // reader, as well as every ancestor needed to serialize a legal line.
    if (editing) _promotePath(_activeBranchPly, _analysisPath);
    _currentPosition = newPos;
    return ViewerMoveKind.variation;
  }

  /// Record [san] as an ephemeral alternative at the current position —
  /// a sideline root on the mainline, a child of the current node inside a
  /// sideline — without navigating into it (solitaire wrong attempts, shown
  /// live). Returns whether a node was added.
  bool recordVariationMove(String san) {
    final newPos = _tryPlay(_currentPosition, san);
    if (newPos == null) return false;
    final siblings = _analysisPath.isNotEmpty
        ? _analysisPath.last.children
        : _variationsByPly.putIfAbsent(_mainLineIndex, () => []);
    if (_siblingWithSan(siblings, san) != null) return false;
    _markPath(
      _analysisPath.isEmpty ? _mainLineIndex : _activeBranchPly,
      _analysisPath,
    );
    siblings.add(
      MoveNode(san: san, fen: newPos.fen, position: newPos, isEphemeral: true),
    );
    return true;
  }

  /// The sideline node with [id], wherever it lives; null when absent.
  MoveNodeSnapshot? findNodeById(int id) =>
      variationsByPly.findNodeById(id) as MoveNodeSnapshot?;

  // ── Solitaire results ────────────────────────────────────────────────

  /// Persist wrong solitaire guesses made inside sidelines as saved
  /// alternatives under the node they were played from ([wrongByParentId]
  /// keyed by [MoveNode.id]). Live ephemeral matches are promoted, not
  /// duplicated. Returns whether anything changed (→ persist).
  bool addGuessNodeVariations(Map<int, List<String>> wrongByParentId) {
    var changed = false;
    for (final MapEntry(key: parentId, value: sans)
        in wrongByParentId.entries) {
      final location = _locate(parentId);
      if (location == null) continue;
      final (ply, path) = location;
      final parent = path.last;
      final from = parent.positionOrNull;
      if (from == null) continue;
      for (final san in sans) {
        if (_saveAlternative(parent.children, from, san)) {
          _markPath(ply, [...path, _siblingWithSan(parent.children, san)!]);
          changed = true;
        }
      }
      // A saved child under an ephemeral ancestor would be dropped by the
      // serializer.
      if (_promotePath(ply, path)) changed = true;
    }
    return changed;
  }

  /// Persist wrong solitaire guesses as real (non-ephemeral) sideline roots
  /// at each guessed ply; live ephemeral matches are promoted, not
  /// duplicated. Returns whether anything changed (→ persist).
  bool addGuessVariations(Map<int, List<String>> wrongByPly) {
    if (wrongByPly.isEmpty || _moveHistory.isEmpty) return false;
    var changed = false;
    for (final MapEntry(key: ply, value: sans) in wrongByPly.entries) {
      if (ply < 0 || ply >= _moveHistory.length || sans.isEmpty) continue;
      final from = mainline.tryAt(ply);
      if (from == null) continue;
      final roots = _variationsByPly.putIfAbsent(ply, () => []);
      for (final san in sans) {
        if (_saveAlternative(roots, from, san)) {
          _sidelineViews.changed(ply);
          changed = true;
        }
      }
    }
    return changed;
  }

  /// Save [san] as a real alternative among [siblings], all played from
  /// [from]: a live ephemeral match is promoted rather than duplicated, a
  /// saved match is left alone, and an unplayable move is skipped. Returns
  /// whether anything changed.
  static bool _saveAlternative(
    List<MoveNode> siblings,
    Position from,
    String san,
  ) {
    final existing = _siblingWithSan(siblings, san);
    if (existing != null) {
      if (!existing.isEphemeral) return false;
      existing.isEphemeral = false;
      return true;
    }
    final after = _tryPlay(from, san);
    if (after == null) return false;
    siblings.add(
      MoveNode(san: san, fen: after.fen, position: after, isEphemeral: false),
    );
    return true;
  }

  /// Append solitaire guess notes to sideline moves ([notes] keyed by
  /// [MoveNode.id]), keeping the line's own comments.
  bool appendGuessNodeNotes(Map<int, String> notes) {
    var changed = false;
    for (final MapEntry(key: id, value: note) in notes.entries) {
      final node = findNodeById(id);
      if (node == null) continue;
      final appended = _withNote(node.comment ?? '', note);
      if (appended == null) continue;
      setNodeComment(node, appended);
      changed = true;
    }
    return changed;
  }

  /// Append solitaire guess notes to mainline move comments, keeping the
  /// game's own annotations.
  void appendGuessNotes(Map<int, String> notes) {
    for (final MapEntry(key: index, value: note) in notes.entries) {
      if (index < 0 || index >= _moveHistory.length) continue;
      final moveData = _moveHistory[index];
      final appended = _withNote(joinComments(moveData.comments), note);
      if (appended != null) setMainlineComment(index, appended);
    }
  }

  /// [existing] with [note] appended, or null when it already carries it.
  static String? _withNote(String existing, String note) {
    final trimmed = existing.trim();
    if (trimmed.contains(note)) return null;
    return trimmed.isEmpty ? note : '$trimmed $note';
  }

  // ── Clearing / deleting ──────────────────────────────────────────────

  /// Drop every ephemeral node (roots and children) and leave any variation
  /// the cursor was in.
  void clearAnalysis() {
    for (final entry in _variationsByPly.entries) {
      if (entry.value.any((node) => node.subtreeHasEphemeral)) {
        _sidelineViews.changed(entry.key);
      }
    }
    _variationsByPly.removeEphemeral();
    goToMainLineMove(_mainLineIndex);
  }

  /// Delete a node, retreating the board/cursor to its surviving parent.
  bool deleteAnalysisNode(int nodeId) {
    final location = _locate(nodeId);
    if (location == null) return false;
    final (ply, path) = location;
    _markPath(ply, path);
    _variationsByPly.removeNode(nodeId);
    if (_variationsByPly[ply]?.isEmpty ?? false) _variationsByPly.remove(ply);
    if (_analysisPath.any((node) => node.id == nodeId)) {
      if (path.length == 1) {
        goToMainLineMove(ply);
      } else {
        goToAnalysisNode(path[path.length - 2], ply);
      }
    }
    return true;
  }

  // ── Annotations ──────────────────────────────────────────────────────

  /// Promote only live nodes; a retained view of a deleted/replaced game is
  /// rejected rather than mutating a detached object and emitting a false save.
  bool promoteNodeLineage(MoveNodeView node) {
    final location = _locate(node.id);
    if (location == null) return false;
    return _promotePath(location.$1, location.$2);
  }

  bool toggleNodeNag(MoveNodeView target, int nagId) {
    final location = _locate(target.id);
    if (location == null) return false;
    final (ply, path) = location;
    _markPath(ply, path);
    _promotePath(ply, path);
    final node = path.last;
    final next = toggleQualityNag(node.nags, nagId);
    node.nags = next.isEmpty ? null : next;
    return true;
  }

  /// Set a live sideline's comment; non-empty prose promotes its ancestry.
  bool setNodeComment(MoveNodeView target, String text) {
    final location = _locate(target.id);
    if (location == null) return false;
    final (ply, path) = location;
    final node = path.last;
    final trimmed = text.trim();
    if ((node.comment ?? '') == trimmed) return false;
    _markPath(ply, path);
    if (trimmed.isNotEmpty) _promotePath(ply, path);
    node.comment = trimmed.isEmpty ? null : trimmed;
    return true;
  }

  bool toggleMainlineNag(int moveIndex, int nagId, {Object? expectedMove}) {
    if (!_matchesMove(moveIndex, expectedMove)) return false;
    final moveData = _moveHistory[moveIndex];
    final next = toggleQualityNag(moveData.nags, nagId);
    moveData.nags = next.isEmpty ? null : next;
    _mainlineChanged(moveData);
    return true;
  }

  /// Replace the whole comment, retaining no caller-owned values. A delayed
  /// panel supplies the move identity it displayed so game replacement cannot
  /// redirect that edit to the same numeric index in a different game.
  bool setMainlineComment(int index, String text, {Object? expectedMove}) {
    if (!_matchesMove(index, expectedMove)) return false;
    final move = _moveHistory[index];
    final trimmed = text.trim();
    if (joinComments(move.comments) == trimmed) return false;
    move.comments = trimmed.isEmpty ? null : [trimmed];
    _mainlineChanged(move);
    return true;
  }

  // ── Serialization ────────────────────────────────────────────────────

  /// Serialize the mainline *and* every saved sideline (with comments and
  /// NAGs) back to PGN movetext, headers stripped so the caller can splice
  /// it under the game's existing headers. Ephemeral nodes are excluded.
  ///
  /// Shares [buildGameMovetext] with the engine-review save path: both write
  /// into the same slot of the same file, so a difference between them is a
  /// difference in what the reader's file keeps.
  String buildAnnotatedMovetext() => buildGameMovetext(
    moves: serializer.buildViewerPgnTree(
      moveHistory: _moveHistory,
      sidelines: _variationsByPly,
    ),
    comments: _game?.comments ?? const [],
    fen: _game?.headers['FEN'],
    result: _game?.headers['Result'],
  );

  /// Move data from the game start to [node]: the mainline up to the branch
  /// point, then the variation path. Null when the node can't be located.
  List<PgnMoveSnapshot>? lineToVariationNode(MoveNodeView node, int branchPly) {
    final path = _variationsByPly.pathToNode(node, branchPly: branchPly);
    if (path == null) return null;
    return [
      for (var i = 0; i < branchPly && i < _moveHistory.length; i++)
        _snapshotOf(_moveHistory[i]),
      for (final n in path)
        PgnMoveSnapshot.capture(serializer.pgnNodeDataFor(n)),
    ];
  }

  /// Serialize a single line to PGN: `[FEN]`/`[SetUp]` headers when the game
  /// starts from a custom position, then numbered movetext (comments and
  /// NAGs of the source moves included).
  String buildLinePgn(List<PgnMoveSnapshot> line) => serializer.buildLinePgn([
    for (final move in line) move.toPgnNodeData(),
  ], setupFen: _game?.headers['FEN']);

  // ── Shared helpers ───────────────────────────────────────────────────

  /// The board after [san] from [pos], or null when it is not a legal move
  /// there. Total: `parseSan` throws on some malformed tokens, and every
  /// caller treats "not a move at all" as "not legal".
  static Position? _tryPlay(Position pos, String san) {
    try {
      final move = pos.parseSan(san);
      return move == null ? null : pos.play(move);
    } catch (_) {
      return null;
    }
  }

  static MoveNode? _siblingWithSan(List<MoveNode> siblings, String san) =>
      siblings.where((n) => n.san == san).firstOrNull;
}

typedef _Cursor = ({
  int mainLineIndex,
  int activeBranchPly,
  List<MoveNode> analysisPath,
  Position position,
});
