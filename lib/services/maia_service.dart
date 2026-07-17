import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'eval_cache.dart';
import 'maia_tensor.dart';
import 'package:chess_auto_prep/utils/log.dart';

class MaiaResult {
  final Map<String, double> policy;
  final double winProbability;

  const MaiaResult({required this.policy, required this.winProbability});
}

class MaiaService {
  /// Application-wide shared instance.
  static final MaiaService instance = MaiaService._internal();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  MaiaService.fresh() : this._internal();

  OrtSession? _session;
  bool _isInitialized = false;
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

      final rawAsset = await rootBundle.load('assets/maia3_simplified.onnx');
      final bytes = rawAsset.buffer.asUint8List();

      // Parsing/optimizing the 45 MB model graph is one long synchronous
      // native call — done here it freezes the UI for the whole duration.
      // Build the session in a short-lived isolate and adopt it by native
      // address (the session outlives the isolate; onnxruntime is
      // thread-safe across isolates).
      final address = await Isolate.run(() {
        OrtEnv.instance.init();
        return OrtSession.fromBuffer(bytes, OrtSessionOptions()).address;
      });
      _session = OrtSession.fromAddress(address);
      _isInitialized = true;
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
    MaiaCache.instance.put(fen, elo, result.policy, result.winProbability);
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

  Future<MaiaResult> _runOnnx(String fen, int elo) async {
    if (!_isInitialized) {
      await initialize();
      if (!_isInitialized) throw Exception('Maia not initialized');
    }

    final inputData = MaiaTensor.preprocess(fen, elo, elo);

    final floatInput = inputData['boardInput'] as Float32List;
    final eloSelf = inputData['eloSelf'] as double;
    final eloOppo = inputData['eloOppo'] as double;
    final legalMovesMask = inputData['legalMoves'] as Float32List;
    final isBlack = inputData['isBlack'] as bool;
    // Board: [1, 64, 12]
    final inputOrt = OrtValueTensor.createTensorWithDataList(floatInput, [
      1,
      64,
      12,
    ]);

    // Elo: Float32 [1]
    final eloSelfOrt = OrtValueTensor.createTensorWithDataList(
      Float32List.fromList([eloSelf]),
      [1],
    );
    final eloOppoOrt = OrtValueTensor.createTensorWithDataList(
      Float32List.fromList([eloOppo]),
      [1],
    );

    final runOptions = OrtRunOptions();

    final inputs = {
      'tokens': inputOrt,
      'elo_self': eloSelfOrt,
      'elo_oppo': eloOppoOrt,
    };

    // runAsync executes the native inference in the package's worker
    // isolate; the UI isolate only does the cheap pre/post-processing.
    final outputs =
        await _session!.runAsync(runOptions, inputs) ?? const <OrtValue?>[];
    if (outputs.isEmpty) {
      inputOrt.release();
      eloSelfOrt.release();
      eloOppoOrt.release();
      runOptions.release();
      throw Exception('Maia inference returned no outputs');
    }

    // Output 0: logits_move [1, 4352]
    // Output 1: logits_value [1, 3] (L/D/W)
    final policyLogits = outputs[0]?.value;
    final valueLogits = outputs[1]?.value;

    List<double> logits;
    if (policyLogits is List) {
      if (policyLogits.isNotEmpty && policyLogits[0] is List) {
        logits = (policyLogits[0] as List).cast<double>();
      } else {
        logits = policyLogits.cast<double>();
      }
    } else {
      throw Exception('Unexpected output format from ONNX model');
    }

    List<double> wdl;
    if (valueLogits is List) {
      if (valueLogits.isNotEmpty && valueLogits[0] is List) {
        wdl = (valueLogits[0] as List).cast<double>();
      } else {
        wdl = valueLogits.cast<double>();
      }
    } else {
      wdl = [0.0, 0.0, 0.0];
    }

    inputOrt.release();
    eloSelfOrt.release();
    eloOppoOrt.release();
    runOptions.release();
    for (var o in outputs) {
      o?.release();
    }

    final winProb = _processWdl(wdl, isBlack);
    final policy = _processLogits(logits, legalMovesMask, isBlack);

    return MaiaResult(policy: policy, winProbability: winProb);
  }

  /// WDL logits → win probability (white perspective).
  /// Indices: 0=Loss, 1=Draw, 2=Win (for side-to-move).
  double _processWdl(List<double> wdl, bool isBlack) {
    if (wdl.length < 3) return 0.5;

    final maxW = math.max(wdl[0], math.max(wdl[1], wdl[2]));
    final expL = math.exp(wdl[0] - maxW);
    final expD = math.exp(wdl[1] - maxW);
    final expW = math.exp(wdl[2] - maxW);
    final sum = expL + expD + expW;

    double winProb = (expW + 0.5 * expD) / sum;
    if (isBlack) winProb = 1.0 - winProb;

    return (winProb * 10000).round() / 10000;
  }

  Map<String, double> _processLogits(
    List<double> logits,
    Float32List legalMask,
    bool isBlack,
  ) {
    final legalIndices = <int>[];
    final legalLogits = <double>[];

    for (int i = 0; i < legalMask.length; i++) {
      if (legalMask[i] > 0) {
        legalIndices.add(i);
        if (i < logits.length) {
          legalLogits.add(logits[i]);
        } else {
          legalLogits.add(-9999.0);
        }
      }
    }

    if (legalLogits.isEmpty) return {};

    final maxLogit = legalLogits.reduce(math.max);
    final expLogits = legalLogits.map((l) => math.exp(l - maxLogit)).toList();
    final sumExp = expLogits.reduce((a, b) => a + b);

    final probs = expLogits.map((e) => e / sumExp).toList();

    final result = <String, double>{};
    for (int i = 0; i < legalIndices.length; i++) {
      final index = legalIndices[i];
      String moveUci = MaiaTensor.getMoveFromIndex(index);

      if (isBlack) {
        moveUci = MaiaTensor.mirrorMove(moveUci);
      }

      result[moveUci] = probs[i];
    }

    final sortedKeys = result.keys.toList()
      ..sort((a, b) => result[b]!.compareTo(result[a]!));

    return Map.fromEntries(sortedKeys.map((k) => MapEntry(k, result[k]!)));
  }

  void dispose() {
    _session?.release();
    _isInitialized = false;
    _initFuture = null;
  }
}
