/// Writing generated repertoire lines to disk.
///
/// Text formatting lives in `export/pgn_game_writer.dart`; this file is the
/// batching layer plus the one flat (chapterless) line format, used by the
/// mid-run snapshot export where no opening book is available.
library;

import 'dart:io';

import '../../constants/chess_constants.dart';
import '../../utils/fen_utils.dart';
import 'export/move_annotation.dart';
import 'export/pgn_game_writer.dart';
import 'line_extractor.dart';

/// Buffers PGN game entries and appends them to a file in batches, so a
/// hundred-line export is a handful of writes rather than a hundred.
class PgnBatchWriter {
  final StringBuffer _buffer = StringBuffer();
  int _lineCount = 0;

  bool get hasPending => _lineCount > 0;

  int get lineCount => _lineCount;

  void queue(String pgn) {
    _buffer.writeln();
    _buffer.write(pgn);
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

/// One repertoire line as a standalone, chapterless PGN game.
///
/// This is the fallback shape: the course exporter produces chapter-tagged
/// games instead (see `course/course_composer.dart`).  Kept for the snapshot
/// export, which runs as a pure function over a serialized tree and has no
/// opening book to name chapters with.
String writeRepertoireLine({
  required List<String> movesSan,
  required String title,
  required ExtractedLine line,
  required bool isWhiteRepertoire,
  required String rootFen,
  required MoveAnnotationDetail detail,
  int annotationOffset = 0,
  int startMoveNumber = 1,
  bool rankByImportance = true,
}) {
  final probability = '${(line.probability * 100).toStringAsFixed(3)}%';
  return writePgnGame(
    PgnGameSpec(
      headers: {
        'Event': title,
        'White': isWhiteRepertoire ? 'Repertoire' : 'Opponent',
        'Black': isWhiteRepertoire ? 'Opponent' : 'Repertoire',
        'Result': '*',
        'Annotator': 'Chess Auto Prep',
        if (rankByImportance) 'CumProb': probability,
      },
      movesSan: movesSan,
      annotations: line.moveAnnotations,
      annotationOffset: annotationOffset,
      startFen: rootFen.isEmpty ? kStandardStartFen : rootFen,
      rootWhiteToMove: isWhiteToMove(rootFen),
      startMoveNumber: startMoveNumber,
      leadingComment: rankByImportance ? '[%cumProb $probability]' : null,
    ),
    detail: detail,
  );
}
