/// Session controller for repertoire coverage analysis.
///
/// Owns the observable coverage state: result, progress, and running flag.
/// The screen initiates analysis via [calculate] and listens for updates.
library;

import 'package:flutter/foundation.dart';

import '../models/opening_tree.dart';
import 'package:chess_auto_prep/features/coverage/models/coverage_config.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../utils/safe_change_notifier.dart';

class CoverageController extends ChangeNotifier with SafeChangeNotifier {
  CoverageResult? _result;
  bool _isRunning = false;
  double? _progress;
  String? _progressMessage;

  CoverageResult? get result => _result;
  bool get isRunning => _isRunning;
  double? get progress => _progress;
  String? get progressMessage => _progressMessage;

  void clear() {
    _result = null;
    notifyListeners();
  }

  /// Run coverage analysis. Returns the result, or null if the tree is null
  /// or an error occurs. Progress is reported via [notifyListeners] and,
  /// when provided, [onProgress] (used to drive the jobs-pane card).
  Future<CoverageResult?> calculate({
    required CoverageConfig config,
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    void Function(String message, double? progress)? onProgress,
  }) async {
    _isRunning = true;
    _result = null;
    _progress = 0.0;
    _progressMessage = 'Starting analysis...';
    notifyListeners();

    final service = CoverageService(
      database: config.database,
      ratings: config.ratingsString,
      speeds: config.speedsString,
      useMaia: config.useMaia,
      maiaElo: config.maiaElo,
    );

    try {
      final coverageResult = await service.analyzeOpeningTree(
        tree,
        targetPercent: config.targetPercent,
        isWhiteRepertoire: isWhiteRepertoire,
        onProgress: (message, prog) {
          _progressMessage = message;
          _progress = prog;
          notifyListeners();
          onProgress?.call(message, prog);
        },
      );

      _result = coverageResult;
      _isRunning = false;
      _progress = null;
      _progressMessage = null;
      notifyListeners();
      return coverageResult;
    } catch (e) {
      _isRunning = false;
      _progress = null;
      _progressMessage = null;
      notifyListeners();
      rethrow;
    }
  }
}
