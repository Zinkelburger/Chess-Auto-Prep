import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/ephemeral_finding_preview.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

AuditFinding _finding({
  AuditFindingType type = AuditFindingType.missingResponse,
  String? missingMove = 'e5',
  List<String> movePath = const ['e4'],
}) {
  return AuditFinding(
    type: type,
    severity: AuditSeverity.warning,
    movePath: movePath,
    fen: _afterE4,
    missingMove: missingMove,
  );
}

void main() {
  group('forFinding', () {
    test('plays the missing move onto the parent position', () {
      final preview = EphemeralFindingPreview.forFinding(_finding(), _afterE4);

      expect(preview, isNotNull);
      expect(preview!.fen, startsWith('rnbqkbnr/pppp1ppp/8/4p3/4P3'));
      expect(preview.finding.missingMove, 'e5');
    });

    test('the line it would create is the path plus the missing move', () {
      final preview = EphemeralFindingPreview.forFinding(
        _finding(movePath: ['e4', 'e5', 'Nf3'], missingMove: 'Nc6'),
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
      );

      expect(preview!.lineMoves, ['e4', 'e5', 'Nf3', 'Nc6']);
    });

    test('hole-hunt uncovered strong moves preview too', () {
      expect(
        EphemeralFindingPreview.forFinding(
          _finding(type: AuditFindingType.uncoveredStrongMove),
          _afterE4,
        ),
        isNotNull,
      );
    });

    test('finding kinds that name no move have nothing to preview', () {
      for (final type in [
        AuditFindingType.mistake,
        AuditFindingType.inaccuracy,
        AuditFindingType.weakPosition,
        AuditFindingType.deadEnd,
      ]) {
        expect(
          EphemeralFindingPreview.forFinding(_finding(type: type), _afterE4),
          isNull,
          reason: 'for $type',
        );
      }
    });

    test('a finding without a move has nothing to preview', () {
      expect(
        EphemeralFindingPreview.forFinding(
          _finding(missingMove: null),
          _afterE4,
        ),
        isNull,
      );
    });

    test('a move that is illegal here is dropped, not thrown', () {
      // Stale audit against an edited repertoire: the cursor is somewhere the
      // suggested move cannot be played.
      expect(
        EphemeralFindingPreview.forFinding(
          _finding(missingMove: 'Qh8'),
          _afterE4,
        ),
        isNull,
      );
    });

    test('an unparseable position is dropped, not thrown', () {
      expect(
        EphemeralFindingPreview.forFinding(_finding(), 'not a fen'),
        isNull,
      );
    });
  });
}
