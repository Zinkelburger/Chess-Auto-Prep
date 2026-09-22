import '../chess/fen.dart';
import '../diagnostics/log.dart';
import '../engines/maia/move_policy.dart';
import '../storage/settings_store.dart';

/// The opponent model's answers at the rating the settings name, each
/// position asked once: the Replies table and the gap walk ask about the
/// same positions, and a chapter walked once is cheap to walk again after
/// an edit.
///
/// The move counters are not part of the position the model sees, so they
/// are not part of the key. Answers stay for the session; a failure is not
/// kept, so the next ask tries again.
final class ReplyModel {
  ReplyModel({required MovePolicy policy, required SettingsStore settings})
    : _policy = policy,
      _settings = settings;

  final MovePolicy _policy;
  final SettingsStore _settings;
  final _cache = <String, Map<String, double>>{};

  /// The model's answer for [fen] at the chosen rating.
  Future<MaiaAnswer> answerAt(Fen fen) async {
    final elo = _settings.value.opponentElo;
    final key = '${fen.position}|$elo';
    final cached = _cache[key];
    if (cached != null) return MaiaPolicy(cached);
    final answer = await _policy.policy(fen, elo);
    if (answer case MaiaPolicy(:final shares)) _cache[key] = shares;
    if (answer case MaiaFailed(:final reason)) {
      log.w('predict replies at ${fen.value}', reason);
    }
    return answer;
  }

  /// The shares at [fen], or null when the model could not say.
  Future<Map<String, double>?> sharesAt(Fen fen) async =>
      switch (await answerAt(fen)) {
        MaiaPolicy(:final shares) => shares,
        MaiaFailed() => null,
      };
}
