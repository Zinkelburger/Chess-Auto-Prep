import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/hivemind_engine.dart';
import '../engines/hivemind_install.dart';
import '../engines/maia/maia_model.dart';
import '../engines/maia/move_policy.dart';
import '../engines/stockfish_install.dart';

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

/// Where the workspace's Stockfish comes from: the bundled asset, installed
/// once under the support folder, then started under [engines] with the
/// threads and the table the settings give it.
Future<EngineStart> launchStockfish({
  required Directory support,
  required EngineSupervisor engines,
  required int cores,
  required int memoryMb,
}) async {
  final install = StockfishInstall(
    supportDirectory: support,
    readAsset: readBundledAsset,
  );
  final location = await install.locate();
  if (location case StockfishMissing(:final reason)) {
    log.e('install Stockfish', reason);
  }
  return switch (location) {
    StockfishMissing(:final reason) => StartFailed(reason),
    StockfishReady(:final path) => engines.start(
      path,
      options: {'Threads': '$cores', 'Hash': '$memoryMb'},
    ),
  };
}

/// The bundle has no way to ask whether an asset exists, only to load it.
Future<Uint8List?> readBundledAsset(String asset) async {
  try {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on FlutterError {
    return null;
  }
}

/// The bughouse engine: installed from the bundle into the support folder,
/// checked against its manifest, then started under [engines].
Future<HivemindStart> launchHivemind({
  required Directory support,
  required EngineSupervisor engines,
  required int cores,
}) async {
  final install = HivemindInstall(
    supportDirectory: support,
    readAsset: readBundledAsset,
  );
  return switch (await install.locate()) {
    HivemindMissing(:final reason) => HivemindStartFailed(reason),
    HivemindReady(:final files) => engines.startHivemind(files, cores: cores),
  };
}

/// Whether this build carries the bughouse engine, from the asset list the
/// build ships: the bundle is fetched separately and may be missing.
Future<bool> bughouseBundled() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return HivemindInstall.bundledIn(manifest.listAssets());
  } on Object catch (error) {
    log.w('read the asset list for the bughouse engine', error);
    return false;
  }
}
