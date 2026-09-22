import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/reply_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers at the start and fails everywhere else, counting every ask.
final class CountingPolicy implements MovePolicy {
  final asked = <String>[];

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async {
    asked.add('${fen.position}@$elo');
    return fen == Fen.initial
        ? const MaiaPolicy({'e2e4': 0.6, 'd2d4': 0.4})
        : const MaiaFailed('no opinion');
  }
}

void main() {
  late CountingPolicy policy;
  late SettingsStore settings;
  late ReplyModel model;

  setUp(() {
    policy = CountingPolicy();
    settings = SettingsStore(initial: const Settings(opponentElo: 2000));
    model = ReplyModel(policy: policy, settings: settings);
  });

  tearDown(() => settings.dispose());

  test('a position is asked once per rating', () async {
    expect(await model.sharesAt(Fen.initial), {'e2e4': 0.6, 'd2d4': 0.4});
    await model.answerAt(Fen.initial);
    expect(policy.asked, hasLength(1));
    await settings.update(settings.value.copyWith(opponentElo: 1500));
    await model.answerAt(Fen.initial);
    expect(policy.asked, hasLength(2));
  });

  test('a failure is not kept, so the next ask tries again', () async {
    const after = Fen(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    );
    expect(await model.sharesAt(after), isNull);
    expect(await model.answerAt(after), isA<MaiaFailed>());
    expect(policy.asked, hasLength(2));
  });
}
