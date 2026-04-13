/// Line extraction from a [BuildTree] after repertoire selection.
///
/// Walks the tree following `isRepertoireMove` flags at our-move nodes
/// and all children at opponent nodes to produce complete lines.
/// Ports C's `extract_lines` from `repertoire.c`.
library;

import '../../models/build_tree_node.dart';
import 'generation_config.dart';

// ── Extracted line ───────────────────────────────────────────────────────

class ExtractedLine {
  final List<String> movesSan;
  final List<String> movesUci;
  final double probability;
  final PruneReason leafPruneReason;
  final int? leafPruneEvalCp;
  final String? openingName;
  final String? openingEco;
  final int? leafEvalCp;

  const ExtractedLine({
    required this.movesSan,
    required this.movesUci,
    required this.probability,
    this.leafPruneReason = PruneReason.none,
    this.leafPruneEvalCp,
    this.openingName,
    this.openingEco,
    this.leafEvalCp,
  });

  /// Format as PGN movetext with annotations.
  String toPgn({required bool rootWhiteToMove, String? event}) {
    final sb = StringBuffer();

    if (event != null) sb.writeln('[Event "$event"]');
    sb.writeln('[Site "tree_builder"]');
    sb.writeln('[Date "????.??.??"]');
    sb.writeln('[Round "-"]');
    sb.writeln('[Result "*"]');
    if (!rootWhiteToMove) {
      sb.writeln('[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1"]');
      sb.writeln('[SetUp "1"]');
    }
    sb.writeln();

    for (int j = 0; j < movesSan.length; j++) {
      final ply = j + (rootWhiteToMove ? 0 : 1);
      if (ply % 2 == 0) {
        sb.write('${(ply ~/ 2) + 1}. ');
      } else if (j == 0 && !rootWhiteToMove) {
        sb.write('${(ply ~/ 2) + 1}... ');
      }
      sb.write('${movesSan[j]} ');
    }

    if (leafPruneReason == PruneReason.evalTooHigh &&
        leafPruneEvalCp != null) {
      sb.write('{Already winning '
          '(${leafPruneEvalCp! >= 0 ? "+" : ""}${(leafPruneEvalCp! / 100).toStringAsFixed(1)}); '
          'no further preparation needed} ');
    }
    sb.write('*');
    return sb.toString();
  }
}

// ── Extractor ────────────────────────────────────────────────────────────

class LineExtractor {
  final TreeBuildConfig config;

  LineExtractor({required this.config});

  /// Extract complete repertoire lines from the tree.
  List<ExtractedLine> extract(BuildTree tree, {int maxLines = 10000}) {
    final lines = <ExtractedLine>[];
    _extractDfs(
      node: tree.root,
      movesSan: const [],
      movesUci: const [],
      lines: lines,
      maxLines: maxLines,
    );
    return lines;
  }

  void _extractDfs({
    required BuildTreeNode node,
    required List<String> movesSan,
    required List<String> movesUci,
    required List<ExtractedLine> lines,
    required int maxLines,
  }) {
    if (lines.length >= maxLines) return;

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    bool pushedAny = false;

    if (isOurMove) {
      // Find the selected repertoire child
      final selected = node.children
          .where((c) => c.isRepertoireMove)
          .firstOrNull;
      if (selected != null) {
        pushedAny = true;
        _extractDfs(
          node: selected,
          movesSan: [...movesSan, selected.moveSan],
          movesUci: [...movesUci, selected.moveUci],
          lines: lines,
          maxLines: maxLines,
        );
      }
    } else {
      for (final child in node.children) {
        if (child.cumulativeProbability < config.minProbability) continue;
        pushedAny = true;
        _extractDfs(
          node: child,
          movesSan: [...movesSan, child.moveSan],
          movesUci: [...movesUci, child.moveUci],
          lines: lines,
          maxLines: maxLines,
        );
      }
    }

    // Leaf or no valid children → record line
    if (!pushedAny && movesSan.isNotEmpty) {
      // Only record lines that end on an opponent move or after our reply
      // (trim trailing opponent half-move if it's the last move)
      if (movesSan.isNotEmpty) {
        // Find deepest opening info along the path
        String? openingName;
        String? openingEco;
        BuildTreeNode? current = node;
        while (current != null) {
          if (current.openingName != null) {
            openingName = current.openingName;
            openingEco = current.openingEco;
            break;
          }
          current = current.parent;
        }

        lines.add(ExtractedLine(
          movesSan: movesSan,
          movesUci: movesUci,
          probability: node.cumulativeProbability,
          leafPruneReason: node.pruneReason,
          leafPruneEvalCp: node.pruneEvalCp,
          openingName: openingName,
          openingEco: openingEco,
          leafEvalCp: node.engineEvalCp,
        ));
      }
    }
  }

  /// Export all extracted lines as a single PGN string.
  String exportPgn(List<ExtractedLine> lines, {String? repertoireName}) {
    final rootWhiteToMove = config.startFen.split(' ')[1] == 'w';
    return lines.asMap().entries.map((e) {
      final idx = e.key + 1;
      final eventName = repertoireName != null
          ? '$repertoireName Line #$idx'
          : 'Repertoire Line #$idx';
      return e.value.toPgn(
        rootWhiteToMove: rootWhiteToMove,
        event: eventName,
      );
    }).join('\n\n');
  }
}
