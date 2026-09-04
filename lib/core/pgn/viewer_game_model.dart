/// The PGN viewer's game state — the parsed game, its flat mainline spine,
/// the per-ply sideline trees, and the navigation cursor — extracted from
/// `pgn_viewer_widget.dart` so the logic every consumer leans on (solitaire,
/// the viewer screen, the tactics panes) is a real collaborator with unit
/// tests instead of widget-private mutation spread over four mixins.
///
/// The widget keeps rendering-only state (inline comment-line previews,
/// context menus, comment editors) and wraps each mutation here in its own
/// `setState`/notification; methods that move the cursor return `true` when
/// they acted so the caller knows whether to notify.
library;

import '../../utils/pgn_nags.dart';
import 'package:dartchess/dartchess.dart';

import '../../models/move_tree.dart';
import '../../services/pgn_parsing_service.dart' show startPositionFromGame;
import '../../utils/fen_utils.dart';
import '../../utils/pgn_comment_utils.dart' show joinComments;
import 'mainline_positions.dart';
import 'pgn_dummy_mainline.dart';
import 'pgn_variation_extractor.dart';
import 'solitaire_reveal.dart';

/// What [ViewerGameModel.addMove] did with the move.
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

class ViewerGameModel {
  PgnGame? game;
  List<PgnNodeData> moveHistory = [];
  Position startPosition = Chess.initial;
  Position currentPosition = Chess.initial;

  /// Sidelines: ply (0-based mainline index of the branch point) → roots.
  Map<int, List<MoveNode>> variationsByPly = {};

  int mainLineIndex = 0;
  int activeBranchPly = -1;
  List<MoveNode> analysisPath = [];

  /// What a running solitaire session lets the reader see: mainline
  /// navigation never walks past its frontier ply, and sidelines it has not
  /// reached cannot be entered. Null when no session is running.
  SolitaireReveal? reveal;

  /// Solitaire mainline frontier, or null when no session is running.
  int? get revealedPly => reveal?.mainlinePly;

  /// Whether a sideline node may be shown or entered right now.
  bool isNodeVisible(MoveNode node, int branchPly) =>
      reveal?.isNodeVisible(node, branchPly) ?? true;

  bool get hasAnalysis => variationsByPly.values.any((l) => l.isNotEmpty);

  /// The board after each mainline ply, computed once and extended as the
  /// mainline grows.  Every navigation reads from here instead of replaying
  /// the game from the start.
  MainlinePositions get mainline =>
      MainlinePositions.of(moveHistory, startPosition);

  bool get hasEphemeralMoves {
    for (final roots in variationsByPly.values) {
      for (final root in roots) {
        if (subtreeHasEphemeral(root)) return true;
      }
    }
    return false;
  }

  // ── Load ─────────────────────────────────────────────────────────────

  /// Adopt a freshly parsed game: mainline spine, start position, and the
  /// PGN's own sidelines. Resets the cursor to the start.
  void load(PgnGame parsed) {
    promoteNullMoveDummyMainline(parsed.moves);
    game = parsed;
    moveHistory = parsed.moves.mainline().toList();
    startPosition = startPositionFromGame(parsed);
    currentPosition = startPosition;
    variationsByPly = extractPgnVariations(parsed, startPosition);
    mainLineIndex = 0;
    activeBranchPly = -1;
    analysisPath = [];
  }

  /// Take the annotations of a re-parsed copy of the loaded game — comments
  /// and glyphs on the mainline moves — without touching the cursor, the
  /// sidelines, or any analysis in progress.
  ///
  /// This is what an engine pass hands back: the same moves, now with
  /// `[%eval]`/`[%pv]` comments on them. Reloading for that would park the
  /// reader back at move one (and restart a solitaire game), so the model
  /// adopts the new comments in place instead. Returns false when [parsed]
  /// is not the same game — a different mainline, or a different set of
  /// stored sidelines — in which case the caller must reload.
  bool adoptAnnotations(PgnGame parsed) {
    promoteNullMoveDummyMainline(parsed.moves);
    final incoming = parsed.moves.mainline().toList();
    if (incoming.length != moveHistory.length) return false;
    for (var i = 0; i < incoming.length; i++) {
      if (incoming[i].san != moveHistory[i].san) return false;
    }
    // Sidelines stored in the PGN must be the ones already loaded; only
    // in-memory analysis (ephemeral nodes) may differ.
    final storedRoots = extractPgnVariations(parsed, startPosition);
    for (final ply in {...storedRoots.keys, ...variationsByPly.keys}) {
      final theirs = storedRoots[ply]?.length ?? 0;
      final mine = (variationsByPly[ply] ?? const [])
          .where((n) => !n.isEphemeral)
          .length;
      if (theirs != mine) return false;
    }
    game = parsed;
    for (var i = 0; i < incoming.length; i++) {
      moveHistory[i]
        ..comments = incoming[i].comments
        ..startingComments = incoming[i].startingComments
        ..nags = incoming[i].nags;
    }
    return true;
  }

  // ── Navigation ───────────────────────────────────────────────────────

  /// Park the cursor after [moveIndex] mainline half-moves (clamped to the
  /// solitaire frontier). Returns false when the index is out of range.
  bool goToMainLineMove(int moveIndex) {
    if (revealedPly != null && moveIndex > revealedPly!) {
      moveIndex = revealedPly!;
    }
    if (moveIndex < 0 || moveIndex > moveHistory.length) return false;
    mainLineIndex = moveIndex;
    currentPosition = mainline.at(moveIndex);
    analysisPath = [];
    activeBranchPly = -1;
    return true;
  }

  /// Mainline index whose position matches [targetFen], or null when the
  /// game never reaches it. Index 0 is the start position.
  int? mainlineIndexOfFen(String targetFen) =>
      mainline.indexOfFen(normalizeFen(targetFen));

  /// Move the cursor onto [targetNode] inside the sidelines rooted at
  /// [branchPly]. Returns false when the node can't be located.
  bool goToAnalysisNode(MoveNode targetNode, int branchPly) {
    if (!isNodeVisible(targetNode, branchPly)) return false;
    final roots = variationsByPly[branchPly];
    if (roots == null) return false;
    final path = findPathToNode(targetNode, roots);
    if (path == null) return false;

    mainLineIndex = branchPly;
    activeBranchPly = branchPly;
    // Every sideline node carries the board after its move, so the target
    // is one lookup rather than a replay of the branch prefix and the path.
    currentPosition = path.isEmpty
        ? mainline.at(branchPly)
        : path.last.position;
    analysisPath = path;
    return true;
  }

  List<MoveNode>? findPathToNode(MoveNode target, List<MoveNode> roots) {
    for (final root in roots) {
      final path = _findPathRecursive(root, target, []);
      if (path != null) return path;
    }
    return null;
  }

  List<MoveNode>? _findPathRecursive(
    MoveNode current,
    MoveNode target,
    List<MoveNode> pathSoFar,
  ) {
    final newPath = [...pathSoFar, current];
    if (current.id == target.id) return newPath;
    for (final child in current.children) {
      final result = _findPathRecursive(child, target, newPath);
      if (result != null) return result;
    }
    return null;
  }

  /// Inline comment-line preview: the widget steps the board through a
  /// comment's move run without touching the trees; the model just records
  /// the anchored mainline index and the preview board.
  void setInlinePreviewPosition(int baseIndex, Position pos) {
    mainLineIndex = baseIndex;
    analysisPath = [];
    activeBranchPly = -1;
    currentPosition = pos;
  }

  // ── Adding moves ─────────────────────────────────────────────────────

  /// Play [san] at the cursor. [editing] marks additions permanent (amend
  /// mode); [allowMainline] is false while an inline preview owns the board,
  /// which forbids the two mainline fast paths.
  ViewerMoveKind addMove(
    String san, {
    required bool editing,
    required bool allowMainline,
  }) {
    final parsedMove = currentPosition.parseSan(san);
    if (parsedMove == null) return ViewerMoveKind.illegal;
    final Position newPos;
    try {
      newPos = currentPosition.play(parsedMove);
    } catch (_) {
      return ViewerMoveKind.illegal;
    }
    final fenAfter = newPos.fen;

    // Amend mode at the end of the mainline: extend it rather than fork.
    if (editing &&
        analysisPath.isEmpty &&
        allowMainline &&
        mainLineIndex == moveHistory.length) {
      moveHistory.add(PgnNodeData(san: san));
      mainLineIndex = moveHistory.length;
      currentPosition = newPos;
      return ViewerMoveKind.extendedMainline;
    }

    // The game's own next move: follow it instead of duplicating it as a
    // sideline beside itself.
    if (analysisPath.isEmpty &&
        allowMainline &&
        mainLineIndex < moveHistory.length &&
        moveHistory[mainLineIndex].san == san) {
      mainLineIndex++;
      currentPosition = newPos;
      return ViewerMoveKind.followedMainline;
    }

    if (analysisPath.isEmpty) {
      final ply = mainLineIndex;
      final roots = variationsByPly.putIfAbsent(ply, () => []);
      MoveNode? existing;
      for (final root in roots) {
        if (root.san == san) {
          existing = root;
          break;
        }
      }
      if (existing != null) {
        analysisPath = [existing];
      } else {
        final newNode = MoveNode(
          san: san,
          fen: fenAfter,
          position: newPos,
          isEphemeral: !editing,
        );
        roots.add(newNode);
        analysisPath = [newNode];
      }
      activeBranchPly = ply;
    } else {
      final current = analysisPath.last;
      final (node, _) = current.addChild(san, fenAfter, isEphemeral: !editing);
      // A permanent move under ephemeral ancestors would be dropped by the
      // serializer — promote the whole line to saved.
      if (editing) promoteNodeLineage(current);
      analysisPath = [...analysisPath, node];
    }
    currentPosition = newPos;
    return ViewerMoveKind.variation;
  }

  /// Record [san] as an ephemeral alternative at the current position —
  /// a sideline root on the mainline, a child of the current node inside a
  /// sideline — without navigating into it (solitaire wrong attempts, shown
  /// live). Returns whether a node was added.
  bool recordVariationMove(String san) {
    final parsedMove = currentPosition.parseSan(san);
    if (parsedMove == null) return false;
    final Position newPos;
    try {
      newPos = currentPosition.play(parsedMove);
    } catch (_) {
      return false;
    }
    if (analysisPath.isNotEmpty) {
      final parent = analysisPath.last;
      if (parent.children.any((c) => c.san == san)) return false;
      parent.addChild(san, newPos.fen, isEphemeral: true);
      return true;
    }
    final roots = variationsByPly.putIfAbsent(mainLineIndex, () => []);
    if (roots.any((r) => r.san == san)) return false;
    roots.add(
      MoveNode(san: san, fen: newPos.fen, position: newPos, isEphemeral: true),
    );
    return true;
  }

  /// The sideline node with [id], wherever it lives; null when absent.
  MoveNode? findNodeById(int id) {
    MoveNode? visit(MoveNode n) {
      if (n.id == id) return n;
      for (final c in n.children) {
        final hit = visit(c);
        if (hit != null) return hit;
      }
      return null;
    }

    for (final roots in variationsByPly.values) {
      for (final root in roots) {
        final hit = visit(root);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// Persist wrong solitaire guesses made inside sidelines as saved
  /// alternatives under the node they were played from ([wrongByParentId]
  /// keyed by [MoveNode.id]). Live ephemeral matches are promoted, not
  /// duplicated. Returns whether anything changed (→ persist).
  bool addGuessNodeVariations(Map<int, List<String>> wrongByParentId) {
    var changed = false;
    wrongByParentId.forEach((parentId, sans) {
      final parent = findNodeById(parentId);
      final pos = parent?.positionOrNull;
      if (parent == null || pos == null) return;
      for (final san in sans) {
        MoveNode? existing;
        for (final c in parent.children) {
          if (c.san == san) {
            existing = c;
            break;
          }
        }
        if (existing != null) {
          if (existing.isEphemeral) {
            existing.isEphemeral = false;
            changed = true;
          }
          continue;
        }
        final move = pos.parseSan(san);
        if (move == null) continue;
        final Position newPos;
        try {
          newPos = pos.play(move);
        } catch (_) {
          continue;
        }
        parent.addChild(san, newPos.fen, isEphemeral: false);
        changed = true;
      }
      // A saved child under an ephemeral ancestor would be dropped by the
      // serializer.
      promoteNodeLineage(parent);
    });
    return changed;
  }

  /// Append solitaire guess notes to sideline moves ([notes] keyed by
  /// [MoveNode.id]), keeping the line's own comments.
  bool appendGuessNodeNotes(Map<int, String> notes) {
    var changed = false;
    notes.forEach((id, note) {
      final node = findNodeById(id);
      if (node == null) return;
      final existing = (node.comment ?? '').trim();
      if (existing.contains(note)) return;
      setNodeComment(node, existing.isEmpty ? note : '$existing $note');
      changed = true;
    });
    return changed;
  }

  /// Persist wrong solitaire guesses as real (non-ephemeral) sideline roots
  /// at each guessed ply; live ephemeral matches are promoted, not
  /// duplicated. Returns whether anything changed (→ persist).
  bool addGuessVariations(Map<int, List<String>> wrongByPly) {
    if (wrongByPly.isEmpty || moveHistory.isEmpty) return false;
    var changed = false;
    wrongByPly.forEach((ply, sans) {
      if (ply < 0 || ply >= moveHistory.length || sans.isEmpty) return;
      final pos = mainline.tryAt(ply);
      if (pos == null) return;

      final roots = variationsByPly.putIfAbsent(ply, () => []);
      for (final san in sans) {
        MoveNode? existing;
        for (final r in roots) {
          if (r.san == san) {
            existing = r;
            break;
          }
        }
        if (existing != null) {
          if (existing.isEphemeral) {
            existing.isEphemeral = false;
            changed = true;
          }
          continue;
        }
        final move = pos.parseSan(san);
        if (move == null) continue;
        final Position newPos;
        try {
          newPos = pos.play(move);
        } catch (_) {
          continue;
        }
        roots.add(
          MoveNode(
            san: san,
            fen: newPos.fen,
            position: newPos,
            isEphemeral: false,
          ),
        );
        changed = true;
      }
    });
    return changed;
  }

  /// Append solitaire guess notes to mainline move comments, keeping the
  /// game's own annotations.
  void appendGuessNotes(Map<int, String> notes) {
    notes.forEach((index, note) {
      if (index < 0 || index >= moveHistory.length) return;
      final moveData = moveHistory[index];
      final existing = joinComments(moveData.comments);
      if (existing.contains(note)) return;
      writeWholeComment(moveData, existing.isEmpty ? note : '$existing $note');
    });
  }

  // ── Clearing / deleting ──────────────────────────────────────────────

  /// Drop every ephemeral node (roots and children) and leave any variation
  /// the cursor was in.
  void clearAnalysis() {
    final keysToRemove = <int>[];
    for (final entry in variationsByPly.entries) {
      entry.value.removeWhere((n) => n.isEphemeral);
      for (final root in entry.value) {
        _removeEphemeralChildren(root);
      }
      if (entry.value.isEmpty) keysToRemove.add(entry.key);
    }
    for (final k in keysToRemove) {
      variationsByPly.remove(k);
    }
    analysisPath = [];
    activeBranchPly = -1;
  }

  void _removeEphemeralChildren(MoveNode node) {
    node.children.removeWhere((c) => c.isEphemeral);
    for (final child in node.children) {
      _removeEphemeralChildren(child);
    }
  }

  bool subtreeHasEphemeral(MoveNode node) {
    if (node.isEphemeral) return true;
    for (final child in node.children) {
      if (subtreeHasEphemeral(child)) return true;
    }
    return false;
  }

  /// Delete the sideline node with [nodeId] wherever it lives; the cursor
  /// retreats out of the deleted subtree.
  void deleteAnalysisNode(int nodeId) {
    for (final entry in variationsByPly.entries) {
      final ply = entry.key;
      final roots = entry.value;

      final lengthBefore = roots.length;
      roots.removeWhere((n) => n.id == nodeId);
      if (roots.length < lengthBefore) {
        if (activeBranchPly == ply && analysisPath.isNotEmpty) {
          analysisPath = [];
          activeBranchPly = -1;
        }
        return;
      }

      // Search below the roots. Seeded with the roots themselves — the
      // helper matches against each node's *children*, so seeding it one
      // level down (as the pre-extraction code did) silently skipped nodes
      // sitting directly under a variation root.
      if (_removeNodeRecursive(roots, nodeId)) {
        final idx = analysisPath.indexWhere((n) => n.id == nodeId);
        if (idx != -1) {
          if (idx == 0) {
            analysisPath = [];
            activeBranchPly = -1;
          } else {
            analysisPath = analysisPath.sublist(0, idx);
            goToAnalysisNode(analysisPath.last, activeBranchPly);
          }
        }
        return;
      }
    }
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

  // ── Annotations ──────────────────────────────────────────────────────

  /// Mark [node] and every ancestor up to its variation root as saved: the
  /// serializer drops ephemeral nodes wholesale, so an annotation or
  /// permanent move under an ephemeral ancestor would never reach the file.
  void promoteNodeLineage(MoveNode node) {
    for (final roots in variationsByPly.values) {
      final path = findPathToNode(node, roots);
      if (path == null) continue;
      for (final n in path) {
        n.isEphemeral = false;
      }
      return;
    }
  }

  void toggleNodeNag(MoveNode node, int nagId) {
    promoteNodeLineage(node);
    final next = toggleQualityNag(node.nags, nagId);
    node.nags = next.isEmpty ? null : next;
  }

  /// Set the comment on a sideline [node]; a non-empty comment promotes the
  /// node's lineage so it persists.
  void setNodeComment(MoveNode node, String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) promoteNodeLineage(node);
    node.comment = trimmed.isEmpty ? null : trimmed;
  }

  void toggleMainlineNag(int moveIndex, int nagId) {
    if (moveIndex < 0 || moveIndex >= moveHistory.length) return;
    final moveData = moveHistory[moveIndex];
    final next = toggleQualityNag(moveData.nags, nagId);
    moveData.nags = next.isEmpty ? null : next;
  }

  /// Write [text] as the move's *whole* comment, replacing every block it
  /// had: the editors read a move's comment with [joinComments], so what the
  /// user edited is all of it — writing into `comments[0]` and leaving the
  /// rest would duplicate the blocks they just merged.
  static void writeWholeComment(PgnNodeData moveData, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      moveData.comments?.clear();
    } else {
      moveData.comments = [trimmed];
    }
  }

  // ── Serialization ────────────────────────────────────────────────────

  static final _headerLineRe = RegExp(r'^\s*\[.*\]\s*$', multiLine: true);

  /// Serialize the mainline *and* every saved sideline (with comments and
  /// NAGs) back to PGN movetext, headers stripped so the caller can splice
  /// it under the game's existing headers. Ephemeral nodes are excluded.
  String buildAnnotatedMovetext() {
    final headers = <String, String>{};
    final fen = game?.headers['FEN'];
    if (fen != null && fen.isNotEmpty) headers['FEN'] = fen;
    final result = game?.headers['Result'];
    if (result != null && result.isNotEmpty) headers['Result'] = result;

    final serializable = PgnGame<PgnNodeData>(
      headers: headers,
      moves: _buildPgnTree(),
      comments: game?.comments ?? const [],
    );
    return serializable.makePgn().replaceAll(_headerLineRe, '').trim();
  }

  /// Rebuild a dartchess move tree from the flat mainline plus the per-ply
  /// sidelines. Inverts [extractPgnVariations]: sidelines keyed at ply `p`
  /// are siblings of the mainline move at index `p`.
  PgnNode<PgnNodeData> _buildPgnTree() {
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> parent = root;

    void addSidelines(int ply) {
      final roots = variationsByPly[ply];
      if (roots == null) return;
      for (final sideline in roots) {
        if (sideline.isEphemeral) continue;
        parent.children.add(_moveNodeToPgnChild(sideline));
      }
    }

    for (int i = 0; i < moveHistory.length; i++) {
      final mainChild = PgnChildNode<PgnNodeData>(moveHistory[i]);
      parent.children.add(mainChild); // index 0 = mainline continuation
      addSidelines(i); // alternatives to moveHistory[i], sharing `parent`
      parent = mainChild;
    }
    // Sidelines branching after the final mainline move (user-added only).
    addSidelines(moveHistory.length);
    return root;
  }

  static PgnChildNode<PgnNodeData> _moveNodeToPgnChild(MoveNode node) {
    final hasComment = node.comment != null && node.comment!.trim().isNotEmpty;
    final hasNags = node.nags != null && node.nags!.isNotEmpty;
    final child = PgnChildNode<PgnNodeData>(
      PgnNodeData(
        san: node.san,
        comments: hasComment ? [node.comment!.trim()] : null,
        nags: hasNags ? List<int>.from(node.nags!) : null,
      ),
    );
    for (final c in node.children) {
      if (c.isEphemeral) continue;
      child.children.add(_moveNodeToPgnChild(c));
    }
    return child;
  }

  /// Move data from the game start to [node]: the mainline up to the branch
  /// point, then the variation path. Null when the node can't be located.
  List<PgnNodeData>? lineToVariationNode(MoveNode node, int branchPly) {
    final roots = variationsByPly[branchPly];
    if (roots == null) return null;
    final path = findPathToNode(node, roots);
    if (path == null) return null;
    return [
      for (int i = 0; i < branchPly && i < moveHistory.length; i++)
        moveHistory[i],
      for (final n in path)
        PgnNodeData(
          san: n.san,
          comments: (n.comment != null && n.comment!.trim().isNotEmpty)
              ? [n.comment!.trim()]
              : null,
          nags: (n.nags != null && n.nags!.isNotEmpty)
              ? List<int>.from(n.nags!)
              : null,
        ),
    ];
  }

  /// Serialize a single line to PGN: `[FEN]`/`[SetUp]` headers when the game
  /// starts from a custom position, then numbered movetext (comments and
  /// NAGs of the source moves included).
  String buildLinePgn(List<PgnNodeData> line) {
    final headers = <String, String>{};
    final fen = game?.headers['FEN'];
    if (fen != null && fen.isNotEmpty) {
      headers['FEN'] = fen;
      headers['SetUp'] = '1';
    }
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> parent = root;
    for (final data in line) {
      final child = PgnChildNode<PgnNodeData>(data);
      parent.children.add(child);
      parent = child;
    }
    return PgnGame<PgnNodeData>(
      headers: headers,
      moves: root,
      comments: const [],
    ).makePgn().trim();
  }
}
