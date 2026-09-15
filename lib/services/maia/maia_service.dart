/// Maia-3 inference: the bundled ONNX model behind a cache.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import '../../utils/log.dart';
import '../eval_cache.dart';
import 'maia_postprocess.dart';
import 'maia_session.dart';
import 'maia_tensor.dart';

/// Thrown when inference cannot run or the model answered in a shape the
/// service does not understand.
class MaiaException implements Exception {
  const MaiaException(this.message);
  final String message;

  @override
  String toString() => 'MaiaException: $message';
}

class MaiaResult {
  /// Move probabilities keyed by standard UCI, most likely first.
  final Map<String, double> policy;

  /// White's win probability.
  final double winProbability;

  const MaiaResult({required this.policy, required this.winProbability});
}

class MaiaService {
  /// Application-wide shared instance.
  static final MaiaService instance = MaiaService._internal();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  MaiaService.fresh() : this._internal();

  static const String _modelAsset = 'assets/maia3_simplified.onnx';

  /// Shape of the board input the model declares: `[1, 64, 12]`.
  static const List<int> _boardShape = [1, 64, 12];

  OrtSession? _session;
  Future<void>? _initFuture;

  MaiaService._internal();

  /// Idempotent: concurrent callers share one load, and a failed load is
  /// latched (not retried per evaluate) — model assets don't appear at
  /// runtime, and re-loading the ONNX buffer on every call is expensive.
  Future<void> initialize() => _initFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    try {
      await MaiaTensor.init();

      OrtEnv.instance.init();

      final rawAsset = await rootBundle.load(_modelAsset);
      final bytes = rawAsset.buffer.asUint8List();

      // Parsing/optimizing the 45 MB model graph is one long synchronous
      // native call — done here it freezes the UI for the whole duration.
      // Build the session in a short-lived isolate and adopt it by native
      // address (the session outlives the isolate; onnxruntime is
      // thread-safe across isolates).
      final address = await Isolate.run(() {
        OrtEnv.instance.init();
        return createMaiaSession(bytes);
      });
      _session = OrtSession.fromAddress(address);
      log.i('Maia-3 model initialized successfully');
    } catch (e) {
      log.e('Failed to initialize Maia-3: $e');
    }
  }

  Future<MaiaResult> evaluate(String fen, int elo) async {
    final cached = await MaiaCache.instance.get(fen, elo);
    if (cached != null) {
      return MaiaResult(policy: cached.policy, winProbability: cached.winProb);
    }

    final result = await _evaluateOnnx(fen, elo);
    // Not awaited: the write is batched behind a 500 ms timer, and this call
    // sits on the node-expansion critical path.  The in-memory mirror is
    // filled synchronously, so the next `get` for this position hits it
    // regardless of when the batch commits.
    MaiaCache.instance.putSoon(fen, elo, result.policy, result.winProbability);
    return result;
  }

  /// Chains inference calls so only one is in flight: the isolate session
  /// behind [OrtSession.runAsync] pairs requests with responses by order
  /// alone, so overlapping calls could receive each other's outputs.
  Future<void> _evalQueue = Future.value();

  Future<MaiaResult> _evaluateOnnx(String fen, int elo) {
    final result = _evalQueue.then((_) => _runOnnx(fen, elo));
    _evalQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<OrtSession> _readySession() async {
    await initialize();
    final session = _session;
    if (session == null) throw const MaiaException('Maia not initialized');
    return session;
  }

  Future<MaiaResult> _runOnnx(String fen, int elo) async {
    final session = await _readySession();
    final input = MaiaTensor.preprocess(fen, elo, elo);

    final boardTensor = OrtValueTensor.createTensorWithDataList(
      input.boardInput,
      _boardShape,
    );
    final eloSelfTensor = OrtValueTensor.createTensorWithDataList(
      Float32List.fromList([input.eloSelf]),
      [1],
    );
    final eloOppoTensor = OrtValueTensor.createTensorWithDataList(
      Float32List.fromList([input.eloOppo]),
      [1],
    );
    final runOptions = OrtRunOptions();
    final inputs = {
      'tokens': boardTensor,
      'elo_self': eloSelfTensor,
      'elo_oppo': eloOppoTensor,
    };

    List<OrtValue?> outputs = const [];
    try {
      // runAsync executes the native inference in the package's worker
      // isolate; the UI isolate only does the cheap pre/post-processing.
      outputs = await session.runAsync(runOptions, inputs) ?? const [];
      if (outputs.isEmpty) {
        throw const MaiaException('Maia inference returned no outputs');
      }

      // Output 0: logits_move [1, 4352]
      // Output 1: logits_value [1, 3] (L/D/W)
      final logits = _rowOf(outputs[0]?.value);
      if (logits == null) {
        throw const MaiaException('Unexpected output format from ONNX model');
      }
      final wdl = _rowOf(outputs[1]?.value) ?? const [0.0, 0.0, 0.0];

      return MaiaResult(
        policy: policyFromLogits(
          logits,
          input.legalMoves,
          isBlack: input.isBlack,
          moveOf: MaiaTensor.getMoveFromIndex,
          mirrorMove: MaiaTensor.mirrorMove,
        ),
        winProbability: winProbabilityFromWdl(wdl, isBlack: input.isBlack),
      );
    } finally {
      boardTensor.release();
      eloSelfTensor.release();
      eloOppoTensor.release();
      runOptions.release();
      for (final output in outputs) {
        output?.release();
      }
    }
  }

  /// The single row of a `[1, n]` output, or a flat `[n]` one; null when the
  /// value is not a list at all.
  static List<double>? _rowOf(Object? value) {
    if (value is! List) return null;
    if (value.isNotEmpty && value[0] is List) {
      return (value[0] as List).cast<double>();
    }
    return value.cast<double>();
  }

  void dispose() {
    _session?.release();
    _session = null;
    _initFuture = null;
  }
}
