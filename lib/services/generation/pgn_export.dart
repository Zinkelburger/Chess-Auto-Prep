/// Writing generated repertoire lines to disk.
///
/// Text formatting lives in `export/pgn_game_writer.dart`; this file is the
/// batching layer plus the one flat (chapterless) line format, used by the
/// mid-run snapshot export where no opening book is available.
library;

import 'engine_tail.dart';
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
/// [engineTail] extends a line that stopped at the build's ply cap with a few
/// plies of raw engine play, appended to the mainline so it is trained along
/// with everything else. The first appended move carries a note saying where
/// preparation stopped — the moves are best play rather than vouched-for
/// theory, and the file should say so even though you drill them.
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
  EngineTail? engineTail,
  List<MoveAnnotation>? annotations,
}) {
  final probability = '${(line.probability * 100).toStringAsFixed(3)}%';
  // [line]'s own annotations unless the caller has something to add — the
  // "improves on" notes, which are probed after the line is extracted.
  final moveAnnotations = annotations ?? line.moveAnnotations;
  final tail = (engineTail == null || engineTail.movesSan.isEmpty)
      ? null
      : engineTail;
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
      movesSan: [...movesSan, if (tail != null) ...tail.movesSan],
      annotations: [
        // Padded to the prepared move count first: a short annotation list
        // would otherwise slide the tail's note onto an earlier move.
        ...moveAnnotations,
        for (
          var i = moveAnnotations.length;
          i < movesSan.length - annotationOffset;
          i++
        )
          MoveAnnotation.none,
        if (tail != null) ...[
          MoveAnnotation(
            note:
                'Engine continuation from here at depth ${tail.depth} — '
                'best play, not prepared theory',
          ),
          for (var i = 1; i < tail.movesSan.length; i++) MoveAnnotation.none,
        ],
      ],
      annotationOffset: annotationOffset,
      startFen: rootFen.isEmpty ? kStandardStartFen : rootFen,
      rootWhiteToMove: isWhiteToMove(rootFen),
      startMoveNumber: startMoveNumber,
      leadingComment: rankByImportance ? '[%cumProb $probability]' : null,
    ),
    detail: detail,
  );
}
