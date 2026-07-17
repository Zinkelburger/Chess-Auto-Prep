import 'dart:io';

import '../../models/build_tree_node.dart';
import '../../utils/movetext_builder.dart';
import 'line_extractor.dart';

/// Buffers PGN game entries and appends them to a file in batches.
class PgnBatchWriter {
  final StringBuffer _buffer = StringBuffer();
  int _lineCount = 0;

  bool get hasPending => _lineCount > 0;

  int get lineCount => _lineCount;

  void queue(String pgn) {
    _buffer.writeln();
    _buffer.writeln(pgn);
    _lineCount++;
  }

  Future<void> flush(String filePath) async {
    if (_lineCount == 0) return;
    final payload = _buffer.toString();
    clear();
    await File(
      filePath,
    ).writeAsString(payload, mode: FileMode.append, flush: true);
  }

  void clear() {
    _buffer.clear();
    _lineCount = 0;
  }
}

String buildRepertoirePgnEntry({
  required List<String> moves,
  required String title,
  required double cumulativeProb,
  required int finalEvalCp,
  required bool isWhiteRepertoire,
  required String rootFen,
  required bool rootWhiteToMove,
  PruneReason? pruneReason,
  int? pruneEvalCp,
  List<MoveProbabilityAnnotation> lineAnnotations = const [],
  int prefixMoveCount = 0,
  bool rankByImportance = true,
  bool annotateMoveProbabilities = true,
  bool annotateMaiaOnly = true,
}) {
  final date = DateTime.now().toIso8601String().split('T').first;
  final whiteName = isWhiteRepertoire ? 'Repertoire' : 'Opponent';
  final blackName = isWhiteRepertoire ? 'Opponent' : 'Repertoire';

  final line = movesToPgnMoveText(
    moves,
    rootWhiteToMove: rootWhiteToMove,
    prefixMoveCount: prefixMoveCount,
    lineAnnotations: lineAnnotations,
    annotateMoveProbabilities: annotateMoveProbabilities,
    annotateMaiaOnly: annotateMaiaOnly,
  );

  final annotation = StringBuffer()
    ..write(
      '{CumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%'
      ', Eval $finalEvalCp cp',
    );
  if (pruneReason == PruneReason.evalTooHigh && pruneEvalCp != null) {
    annotation.write(
      ', Already winning (${pruneEvalCp >= 0 ? "+" : ""}${(pruneEvalCp / 100).toStringAsFixed(1)})',
    );
  }
  if (rankByImportance) {
    annotation.write(
      ', [%cumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%]',
    );
  }
  annotation.write('}');

  const standardStartpos =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  final needsFenHeader = rootFen.isNotEmpty && rootFen != standardStartpos;

  final tags = [
    '[Event "$title"]',
    '[Date "$date"]',
    '[White "$whiteName"]',
    '[Black "$blackName"]',
    '[Result "*"]',
    '[Annotator "AutoGenerate"]',
    if (rankByImportance)
      '[CumProb "${(cumulativeProb * 100).toStringAsFixed(3)}%"]',
    if (needsFenHeader) '[FEN "$rootFen"]',
    if (needsFenHeader) '[SetUp "1"]',
  ];

  return [...tags, '', '$annotation', '$line *'].join('\n');
}

/// Numbered movetext for a generated line, with optional per-move
/// probability annotations. Numbering starts at move 1 with the side given
/// by [rootWhiteToMove]; serialization delegates to the shared
/// [buildNumberedMovetext].
String movesToPgnMoveText(
  List<String> moves, {
  bool rootWhiteToMove = true,
  int prefixMoveCount = 0,
  List<MoveProbabilityAnnotation> lineAnnotations = const [],
  bool annotateMoveProbabilities = true,
  bool annotateMaiaOnly = true,
}) {
  if (moves.isEmpty) return '';
  return buildNumberedMovetext(
    moves,
    whiteToMoveFirst: rootWhiteToMove,
    suffix: (i) {
      if (!annotateMoveProbabilities || i < prefixMoveCount) return null;
      final annIdx = i - prefixMoveCount;
      if (annIdx >= lineAnnotations.length) return null;
      final ann = lineAnnotations[annIdx];
      final sb = StringBuffer();
      if (ann.probability != null) {
        final prob = ann.probability!;
        final tag = ann.fromLichess && !annotateMaiaOnly
            ? '[%humanFrequency ${prob.toStringAsFixed(3)}]'
            : '[%maiaProbability ${prob.toStringAsFixed(3)}]';
        sb.write(' {$tag}');
      }
      if (ann.engineInjected) {
        sb.write(' {engine-injected}');
      }
      return sb.toString();
    },
  );
}
