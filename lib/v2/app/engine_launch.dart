import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/stockfish_install.dart';

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
    readAsset: _readAsset,
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
Future<Uint8List?> _readAsset(String asset) async {
  try {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on FlutterError {
    return null;
  }
}
