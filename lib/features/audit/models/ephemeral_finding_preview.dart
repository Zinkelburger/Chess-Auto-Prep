/// The board preview shown when the user selects an audit finding that names
/// a move the repertoire does not have.
///
/// "Ephemeral" because the move is played for looking at only — it is not in
/// the tree and is not saved unless the user asks to add the line. The screen
/// used to track this as two nullable fields (the finding, and the FEN after
/// its move) that had to be set and cleared together; as one object they
/// cannot drift apart, and the "can this finding even be previewed?" rule has
/// somewhere to live.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/log.dart';
import 'audit_finding.dart';

class EphemeralFindingPreview {
  const EphemeralFindingPreview({required this.finding, required this.fen});

  final AuditFinding finding;

  /// Position with the finding's missing move played.
  final String fen;

  /// The line the user would create by accepting this preview: the path to
  /// the position, plus the move the audit says is missing.
  List<String> get lineMoves => [...finding.movePath, finding.missingMove!];

  /// The preview for [finding] from [parentFen], or null when there is
  /// nothing to show — the finding names no move, is not a kind of finding
  /// that suggests one, or its move does not play from that position (a stale
  /// audit against an edited repertoire).
  static EphemeralFindingPreview? forFinding(
    AuditFinding finding,
    String parentFen,
  ) {
    if (!previewableTypes.contains(finding.type)) return null;
    final san = finding.missingMove;
    if (san == null) return null;

    try {
      final position = Chess.fromSetup(Setup.parseFen(parentFen));
      final move = position.parseSan(san);
      if (move == null) return null;
      return EphemeralFindingPreview(
        finding: finding,
        fen: position.play(move).fen,
      );
    } catch (e) {
      log.d(
        'Failed to preview missing move "$san": $e',
        name: 'EphemeralFindingPreview',
      );
      return null;
    }
  }

  /// Finding kinds that name a move worth putting on the board.
  static const Set<AuditFindingType> previewableTypes = {
    AuditFindingType.missingResponse,
    AuditFindingType.uncoveredStrongMove,
  };
}
