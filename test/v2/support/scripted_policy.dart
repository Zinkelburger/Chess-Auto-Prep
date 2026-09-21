import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';

/// An opponent model with no opinion about anything, for tests whose
/// subject is not the Replies table: it answers at once and asks for no
/// native runtime.
final class NoOpinion implements MovePolicy {
  const NoOpinion();

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async =>
      const MaiaFailed('no model in this test');
}
