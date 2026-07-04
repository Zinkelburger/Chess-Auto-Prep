/// Board arrow annotations for audit findings at the current position.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/log.dart';
import '../../../widgets/chess_board_widget.dart'
    show AnnotationBrush, BoardAnnotation;
import '../models/audit_finding.dart';
import '../models/audit_result.dart';

/// Build board annotations from audit findings matching [currentFen].
///
/// Uses dartchess to resolve SAN moves to origin/dest squares for drawing
/// arrows. Limited to 6 annotations to avoid visual clutter.
List<BoardAnnotation> buildAuditBoardAnnotations({
  required AuditResult? result,
  required String currentFen,
}) {
  if (result == null) return const [];

  final fenPrefix = currentFen.split(' ').take(4).join(' ');

  final relevant = result.findings.where((f) {
    if (f.dismissed) return false;
    final fFenPrefix = f.fen.split(' ').take(4).join(' ');
    return fFenPrefix == fenPrefix;
  }).toList();

  if (relevant.isEmpty) return const [];

  final annotations = <BoardAnnotation>[];
  const maxAnnotations = 6;

  Position? pos;
  try {
    pos = Chess.fromSetup(Setup.parseFen(currentFen));
  } catch (e) {
    log.d('Invalid FEN for audit annotations: $e', name: 'AuditAnnotations');
    return const [];
  }

  for (final f in relevant) {
    if (annotations.length >= maxAnnotations) break;

    final (brush, san) = switch (f.type) {
      AuditFindingType.mistake => (AnnotationBrush.red, f.ourMove),
      AuditFindingType.inaccuracy => (AnnotationBrush.yellow, f.ourMove),
      AuditFindingType.missingResponse => (
          AnnotationBrush.blue,
          f.missingMove
        ),
      _ => (AnnotationBrush.green, null as String?),
    };

    if (san == null) continue;

    final squares = _sanToSquares(pos, san);
    if (squares != null) {
      annotations.add(BoardAnnotation(
        orig: squares.$1,
        dest: squares.$2,
        brush: brush,
      ));
    }
  }

  return annotations;
}

/// Resolve a SAN move to (from, to) square names using dartchess.
(String, String)? _sanToSquares(Position pos, String san) {
  try {
    final move = pos.parseSan(san);
    if (move is NormalMove) {
      return (_squareName(move.from), _squareName(move.to));
    }
  } catch (e) {
    log.d('Failed to parse SAN "$san": $e', name: 'AuditAnnotations');
  }
  return null;
}

String _squareName(int sq) {
  final file = String.fromCharCode(97 + (sq % 8));
  final rank = (sq ~/ 8) + 1;
  return '$file$rank';
}
