import 'dart:io';

import '../../models/build_tree_node.dart';
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
    await File(filePath).writeAsString(
      payload,
      mode: FileMode.append,
      flush: true,
    );
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
    ..write('{CumProb ${(cumulativeProb * 100).toStringAsFixed(3)}%'
        ', Eval $finalEvalCp cp');
  if (pruneReason == PruneReason.evalTooHigh && pruneEvalCp != null) {
    annotation.write(
        ', Already winning (${pruneEvalCp >= 0 ? "+" : ""}${(pruneEvalCp / 100).toStringAsFixed(1)})');
  }
  if (rankByImportance) {
    annotation.write(
        ', [%importance ${cumulativeProb.toStringAsFixed(3)}]');
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
      '[Importance "${cumulativeProb.toStringAsFixed(3)}"]',
    if (needsFenHeader) '[FEN "$rootFen"]',
    if (needsFenHeader) '[SetUp "1"]',
  ];

  return [
    ...tags,
    '',
    '$annotation',
    '$line *',
  ].join('\n');
}

String movesToPgnMoveText(
  List<String> moves, {
  bool rootWhiteToMove = true,
  int prefixMoveCount = 0,
  List<MoveProbabilityAnnotation> lineAnnotations = const [],
  bool annotateMoveProbabilities = true,
  bool annotateMaiaOnly = true,
}) {
  if (moves.isEmpty) return '';
  final sb = StringBuffer();
  for (int i = 0; i < moves.length; i++) {
    final ply = i + (rootWhiteToMove ? 0 : 1);
    if (ply.isEven) {
      sb.write('${(ply ~/ 2) + 1}. ');
    } else if (i == 0 && !rootWhiteToMove) {
      sb.write('${(ply ~/ 2) + 1}... ');
    }
    sb.write(moves[i]);

    if (annotateMoveProbabilities && i >= prefixMoveCount) {
      final annIdx = i - prefixMoveCount;
      if (annIdx < lineAnnotations.length &&
          lineAnnotations[annIdx].probability != null) {
        final ann = lineAnnotations[annIdx];
        final prob = ann.probability!;
        final tag = ann.fromLichess && !annotateMaiaOnly
            ? '[%humanFrequency ${prob.toStringAsFixed(3)}]'
            : '[%maiaProbability ${prob.toStringAsFixed(3)}]';
        sb.write(' {$tag}');
      }
    }
    sb.write(' ');
  }
  return sb.toString().trim();
}
