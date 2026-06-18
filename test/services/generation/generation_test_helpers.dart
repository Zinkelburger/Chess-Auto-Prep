/// Shared synthetic tree builders for generation pipeline tests.
///
/// All trees use realistic FENs and proper parent/child wiring so that
/// downstream code (ease, expectimax, selection, extraction) exercises
/// real logic paths without needing an engine or network.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';

// ── FEN constants ────────────────────────────────────────────────────────

const kFenAfterE4 =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
const kFenAfterD4 =
    'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1';
const kFenAfterE4E5 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';
const kFenAfterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';
const kFenAfterD4D5 =
    'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2';
const kFenAfterD4Nf6 =
    'rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2';
const kFenAfterE4E5Nf3 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
const kFenAfterE4C5Nf3 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';
const kFenAfterD4D5C4 =
    'rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq c3 0 2';
const kFenAfterD4Nf6C4 =
    'rnbqkb1r/pppppppp/5n2/8/2PP4/8/PP2PPPP/RNBQKBNR b KQkq c3 0 2';

// ── Node factory ─────────────────────────────────────────────────────────

int _nextId = 100;

BuildTreeNode makeNode({
  required String fen,
  required String san,
  String uci = '',
  required int ply,
  required bool isWhiteToMove,
  int? evalCp,
  double moveProbability = 1.0,
  double cumulativeProbability = 1.0,
  BuildTreeNode? parent,
  int? nodeId,
}) {
  final node = BuildTreeNode(
    fen: fen,
    moveSan: san,
    moveUci: uci,
    ply: ply,
    isWhiteToMove: isWhiteToMove,
    nodeId: nodeId ?? _nextId++,
    parent: parent,
    moveProbability: moveProbability,
    cumulativeProbability: cumulativeProbability,
  );
  if (evalCp != null) node.engineEvalCp = evalCp;
  if (parent != null) parent.children.add(node);
  return node;
}

void resetNodeIds() => _nextId = 100;

// ── Standard 3-ply white repertoire tree ─────────────────────────────────
//
//  root (start, white to move)
//  ├── e4  (our move, ply 1, black to move)
//  │   ├── e5  (opponent, ply 2, white to move, p=0.55)
//  │   │   └── Nf3 (our move, ply 3, black to move)
//  │   └── c5  (opponent, ply 2, white to move, p=0.35)
//  │       └── Nf3 (our move, ply 3, black to move)
//  └── d4  (our move, ply 1, black to move)
//      ├── d5  (opponent, ply 2, white to move, p=0.45)
//      │   └── c4  (our move, ply 3, black to move)
//      └── Nf6 (opponent, ply 2, white to move, p=0.40)
//          └── c4  (our move, ply 3, black to move)

class StandardTree {
  late final BuildTreeNode root;
  late final BuildTreeNode e4, d4;
  late final BuildTreeNode e4e5, e4c5, d4d5, d4nf6;
  late final BuildTreeNode e4e5nf3, e4c5nf3, d4d5c4, d4nf6c4;

  StandardTree() {
    resetNodeIds();

    root = makeNode(
      fen: kStandardStartFen,
      san: '',
      ply: 0,
      isWhiteToMove: true,
      evalCp: 30,
    );

    // Ply 1: our moves
    e4 = makeNode(
      fen: kFenAfterE4,
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      evalCp: -25,
      parent: root,
    );
    d4 = makeNode(
      fen: kFenAfterD4,
      san: 'd4',
      uci: 'd2d4',
      ply: 1,
      isWhiteToMove: false,
      evalCp: -30,
      parent: root,
    );

    // Ply 2: opponent replies to e4
    e4e5 = makeNode(
      fen: kFenAfterE4E5,
      san: 'e5',
      uci: 'e7e5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 35,
      moveProbability: 0.55,
      cumulativeProbability: 0.55,
      parent: e4,
    );
    e4c5 = makeNode(
      fen: kFenAfterE4C5,
      san: 'c5',
      uci: 'c7c5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 45,
      moveProbability: 0.35,
      cumulativeProbability: 0.35,
      parent: e4,
    );

    // Ply 2: opponent replies to d4
    d4d5 = makeNode(
      fen: kFenAfterD4D5,
      san: 'd5',
      uci: 'd7d5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 25,
      moveProbability: 0.45,
      cumulativeProbability: 0.45,
      parent: d4,
    );
    d4nf6 = makeNode(
      fen: kFenAfterD4Nf6,
      san: 'Nf6',
      uci: 'g8f6',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 40,
      moveProbability: 0.40,
      cumulativeProbability: 0.40,
      parent: d4,
    );

    // Ply 3: our continuations
    e4e5nf3 = makeNode(
      fen: kFenAfterE4E5Nf3,
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -30,
      parent: e4e5,
    );
    e4c5nf3 = makeNode(
      fen: kFenAfterE4C5Nf3,
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -40,
      parent: e4c5,
    );
    d4d5c4 = makeNode(
      fen: kFenAfterD4D5C4,
      san: 'c4',
      uci: 'c2c4',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -20,
      parent: d4d5,
    );
    d4nf6c4 = makeNode(
      fen: kFenAfterD4Nf6C4,
      san: 'c4',
      uci: 'c2c4',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -35,
      parent: d4nf6,
    );
  }

  BuildTree toTree() => BuildTree(root: root, totalNodes: 10);

  /// Populate a FenMap from this tree.
  FenMap toFenMap() {
    final fm = FenMap();
    fm.populate(root);
    return fm;
  }
}

// ── Black repertoire tree (mirror) ───────────────────────────────────────
//
//  root (start, white to move)
//  └── e4  (opponent, ply 1, black to move, p=0.55)
//      ├── e5  (our move, ply 2, white to move)
//      │   └── Nf3 (opponent, ply 3, black to move, p=0.60)
//      └── c5  (our move, ply 2, white to move)
//          └── Nf3 (opponent, ply 3, black to move, p=0.50)

class BlackRepertoireTree {
  late final BuildTreeNode root;
  late final BuildTreeNode e4;
  late final BuildTreeNode e4e5, e4c5;
  late final BuildTreeNode e4e5nf3, e4c5nf3;

  BlackRepertoireTree() {
    resetNodeIds();

    root = makeNode(
      fen: kStandardStartFen,
      san: '',
      ply: 0,
      isWhiteToMove: true,
      evalCp: 30,
    );

    e4 = makeNode(
      fen: kFenAfterE4,
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      evalCp: -25,
      moveProbability: 0.55,
      cumulativeProbability: 0.55,
      parent: root,
    );

    e4e5 = makeNode(
      fen: kFenAfterE4E5,
      san: 'e5',
      uci: 'e7e5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 35,
      parent: e4,
    );
    e4c5 = makeNode(
      fen: kFenAfterE4C5,
      san: 'c5',
      uci: 'c7c5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 45,
      parent: e4,
    );

    e4e5nf3 = makeNode(
      fen: kFenAfterE4E5Nf3,
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -30,
      moveProbability: 0.60,
      cumulativeProbability: 0.55 * 0.60,
      parent: e4e5,
    );
    e4c5nf3 = makeNode(
      fen: kFenAfterE4C5Nf3,
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -40,
      moveProbability: 0.50,
      cumulativeProbability: 0.55 * 0.50,
      parent: e4c5,
    );
  }

  BuildTree toTree() => BuildTree(root: root, totalNodes: 6);

  FenMap toFenMap() {
    final fm = FenMap();
    fm.populate(root);
    return fm;
  }
}
