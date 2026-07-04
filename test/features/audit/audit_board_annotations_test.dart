import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/audit/services/audit_board_annotations.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

AuditFinding _finding({
  AuditFindingType type = AuditFindingType.mistake,
  String fen = _startFen,
  String? ourMove,
  String? missingMove,
  bool dismissed = false,
}) {
  return AuditFinding(
    type: type,
    severity: AuditSeverity.warning,
    movePath: const [],
    fen: fen,
    ourMove: ourMove,
    missingMove: missingMove,
  )..dismissed = dismissed;
}

AuditResult _result(List<AuditFinding> findings) => AuditResult(
      findings: findings,
      nodesChecked: findings.length,
      ourMoveNodesChecked: 0,
      opponentNodesChecked: 0,
      leafNodesChecked: 0,
      elapsed: Duration.zero,
    );

void main() {
  test('returns empty without a result', () {
    expect(
      buildAuditBoardAnnotations(result: null, currentFen: _startFen),
      isEmpty,
    );
  });

  test('draws a red arrow for a mistake at the current position', () {
    final annotations = buildAuditBoardAnnotations(
      result: _result([_finding(ourMove: 'e4')]),
      currentFen: _startFen,
    );
    expect(annotations, hasLength(1));
    expect(annotations.first.brush, AnnotationBrush.red);
    expect(annotations.first.orig, 'e2');
    expect(annotations.first.dest, 'e4');
  });

  test('draws a blue arrow for a missing response', () {
    final annotations = buildAuditBoardAnnotations(
      result: _result([
        _finding(type: AuditFindingType.missingResponse, missingMove: 'Nf3'),
      ]),
      currentFen: _startFen,
    );
    expect(annotations, hasLength(1));
    expect(annotations.first.brush, AnnotationBrush.blue);
    expect(annotations.first.orig, 'g1');
    expect(annotations.first.dest, 'f3');
  });

  test('ignores findings at other positions and dismissed findings', () {
    const otherFen =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    final annotations = buildAuditBoardAnnotations(
      result: _result([
        _finding(fen: otherFen, ourMove: 'e5'),
        _finding(ourMove: 'e4', dismissed: true),
      ]),
      currentFen: _startFen,
    );
    expect(annotations, isEmpty);
  });

  test('matches on the position regardless of move counters', () {
    // Same position, different halfmove/fullmove counters.
    final annotations = buildAuditBoardAnnotations(
      result: _result([_finding(ourMove: 'd4')]),
      currentFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 5 42',
    );
    expect(annotations, hasLength(1));
  });

  test('caps annotations at 6', () {
    final moves = ['e4', 'd4', 'c4', 'Nf3', 'Nc3', 'g3', 'b3', 'f4'];
    final annotations = buildAuditBoardAnnotations(
      result: _result([for (final m in moves) _finding(ourMove: m)]),
      currentFen: _startFen,
    );
    expect(annotations, hasLength(6));
  });
}
