import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'maia_tensor.dart';

class MaiaResult {
  final Map<String, double> policy;
  final double winProbability;

  const MaiaResult({required this.policy, required this.winProbability});
}

class MaiaService {
  static final MaiaService _instance = MaiaService._internal();
  factory MaiaService() => _instance;

  OrtSession? _session;
  bool _isInitialized = false;
  bool _isLoading = false;

  MaiaService._internal();

  Future<void> initialize() async {
    if (_isInitialized || _isLoading) return;
    _isLoading = true;

    try {
      await MaiaTensor.init();

      OrtEnv.instance.init();

      final sessionOptions = OrtSessionOptions();

      final rawAsset = await rootBundle.load('assets/maia3_simplified.onnx');
      final bytes = rawAsset.buffer.asUint8List();

      _session = OrtSession.fromBuffer(bytes, sessionOptions);
      _isInitialized = true;
      print('Maia-3 model initialized successfully');
    } catch (e) {
      print('Failed to initialize Maia-3: $e');
    } finally {
      _isLoading = false;
    }
  }

  Future<MaiaResult> evaluate(String fen, int elo) async {
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
    final inputOrt = OrtValueTensor.createTensorWithDataList(
      floatInput,
      [1, 64, 12],
    );

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

    final outputs = _session!.run(runOptions, inputs);

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
      List<double> logits, Float32List legalMask, bool isBlack) {
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
  }
}
