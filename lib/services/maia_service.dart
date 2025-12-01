import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'maia_tensor.dart';

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
      // Initialize Tensor helpers
      await MaiaTensor.init();

      // Load ONNX model from assets
      // OrtEnv.instance.init(); // Initialize environment once
      // Note: onnxruntime package initialization might vary by version
      OrtEnv.instance.init();

      final sessionOptions = OrtSessionOptions();
      
      // Load model data
      final rawAsset = await rootBundle.load('assets/maia_rapid.onnx');
      final bytes = rawAsset.buffer.asUint8List();
      
      _session = OrtSession.fromBuffer(bytes, sessionOptions);
      _isInitialized = true;
      print('Maia model initialized successfully');
    } catch (e) {
      print('Failed to initialize Maia: $e');
    } finally {
      _isLoading = false;
    }
  }

  Future<Map<String, double>> evaluate(String fen, int elo) async {
    if (!_isInitialized) {
      await initialize();
      if (!_isInitialized) throw Exception('Maia not initialized');
    }

    // Preprocess
    // Maia takes elo_self and elo_oppo. We assume self-play or symmetric elo for "human-like" move prediction.
    final inputData = MaiaTensor.preprocess(fen, elo, elo);
    
    final floatInput = inputData['boardInput'] as Float32List;
    final eloSelfCat = inputData['eloSelfCategory'] as int;
    final eloOppoCat = inputData['eloOppoCategory'] as int;
    final legalMovesMask = inputData['legalMoves'] as Float32List;
    final isBlack = inputData['isBlack'] as bool;

    // Create Tensors
    // Shape: [batch_size, channels, height, width] -> [1, 18, 8, 8]
    final inputOrt = OrtValueTensor.createTensorWithDataList(
      floatInput, 
      [1, 18, 8, 8]
    );
    
    // Elo inputs: Int64 tensors of shape [1]
    // Use correct creation method for Int64
    final eloSelfOrt = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList([eloSelfCat]), 
      [1]
    );
    final eloOppoOrt = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList([eloOppoCat]), 
      [1]
    );

    final runOptions = OrtRunOptions();
    
    // Run Inference
    final inputs = {
      'boards': inputOrt,
      'elo_self': eloSelfOrt,
      'elo_oppo': eloOppoOrt
    };
    
    final outputs = _session!.run(runOptions, inputs);
    
    // Process Outputs
    // Output 0: 'logits_maia' (Policy) - Float32 [1, 19xx] (size of all moves)
    // Output 1: 'logits_value' (Win Prob) - Float32 [1]
    
    // Access data safely
    final policyLogits = outputs[0]?.value; // This is typically a list of lists
    
    List<double> logits;
    if (policyLogits is List) {
        if (policyLogits.isNotEmpty && policyLogits[0] is List) {
             // Nested list case [[...]]
             logits = (policyLogits[0] as List).cast<double>();
        } else {
             // Flat list case [...]
             logits = policyLogits.cast<double>();
        }
    } else {
        throw Exception("Unexpected output format from ONNX model");
    }
    
    // final valueData = (outputs[1] as OrtValueTensor).value as List<dynamic>;
    // final winLogit = (valueData[0] as List)[0] as double;

    // Close tensors to free memory
    inputOrt.release();
    eloSelfOrt.release();
    eloOppoOrt.release();
    runOptions.release();
    
    for (var o in outputs) {
      o?.release();
    }

    // Softmax and filtering
    return _processLogits(logits, legalMovesMask, isBlack);
  }

  Map<String, double> _processLogits(List<double> logits, Float32List legalMask, bool isBlack) {
    // 1. Extract logits only for legal moves
    final legalIndices = <int>[];
    final legalLogits = <double>[];
    
    for (int i = 0; i < legalMask.length; i++) {
      if (legalMask[i] > 0) {
        legalIndices.add(i);
        // Safety check index
        if (i < logits.length) {
          legalLogits.add(logits[i]);
        } else {
          legalLogits.add(-9999.0); // Should not happen
        }
      }
    }

    if (legalLogits.isEmpty) return {};

    // 2. Softmax
    final maxLogit = legalLogits.reduce(math.max);
    final expLogits = legalLogits.map((l) => math.exp(l - maxLogit)).toList();
    final sumExp = expLogits.reduce((a, b) => a + b);
    
    final probs = expLogits.map((e) => e / sumExp).toList();

    // 3. Map back to moves
    final result = <String, double>{};
    for (int i = 0; i < legalIndices.length; i++) {
      final index = legalIndices[i];
      String moveUci = MaiaTensor.getMoveFromIndex(index);
      
      // If we mirrored the board input, we must mirror the move output back
      if (isBlack) {
        moveUci = MaiaTensor.mirrorMove(moveUci);
      }
      
      result[moveUci] = probs[i];
    }
    
    // Sort by probability descending
    final sortedKeys = result.keys.toList()
      ..sort((a, b) => result[b]!.compareTo(result[a]!));
      
    return Map.fromEntries(sortedKeys.map((k) => MapEntry(k, result[k]!)));
  }

  void dispose() {
    _session?.release();
    _isInitialized = false;
  }
}
