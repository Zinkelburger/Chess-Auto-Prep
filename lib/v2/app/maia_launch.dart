import 'dart:async';

import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../diagnostics/log.dart';
import '../engines/maia/maia_model.dart';
import '../engines/maia/move_policy.dart';

/// Where the workspace's opponent model comes from: the bundled Maia-3
/// network and its move table, loaded once, the first time anything asks.
///
/// Loading parses a 45 MB graph, so it is not done at start-up on the
/// chance nobody opens a repertoire; and every caller shares the one load,
/// so two panels asking at once do not build two sessions. A model that
/// cannot load answers every question with the reason, once logged, and
/// is not asked to load again: the assets do not change while the app runs.
final class MaiaLaunch implements MovePolicy {
  Future<MaiaLoad>? _loading;

  Future<MaiaLoad> _load() => _loading ??= _loadOnce();

  Future<MaiaLoad> _loadOnce() async {
    try {
      final model = await rootBundle.load('assets/maia3_simplified.onnx');
      final moves = await rootBundle.loadString(
        'assets/data/all_moves_maia3.json',
      );
      final loaded = await MaiaModel.load(
        model: model.buffer.asUint8List(
          model.offsetInBytes,
          model.lengthInBytes,
        ),
        moveVocabulary: moves,
      );
      if (loaded case MaiaUnavailable(:final reason)) {
        log.e('load the Maia model', reason);
      }
      return loaded;
    } on Object catch (error) {
      log.e('read the Maia assets', error);
      return MaiaUnavailable('The opponent model could not be read: $error');
    }
  }

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async => switch (await _load()) {
    MaiaReady(:final model) => model.policy(fen, elo),
    MaiaUnavailable(:final reason) => MaiaFailed(reason),
  };

  void dispose() {
    unawaited(
      _loading?.then((loaded) {
        if (loaded case MaiaReady(:final model)) model.dispose();
      }),
    );
  }
}
