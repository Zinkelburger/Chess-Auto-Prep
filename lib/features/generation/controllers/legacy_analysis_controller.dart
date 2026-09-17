import 'package:flutter/foundation.dart';

import '../models/generation_artifacts.dart';
import '../../../utils/safe_change_notifier.dart';
import '../services/generation_artifacts.dart';

/// Owns one recovery view; reads and exports without publication or engine work.
class LegacyAnalysisController extends ChangeNotifier with SafeChangeNotifier {
  LegacyAnalysisController(this.artifacts);
  final GenerationArtifacts artifacts;
  LegacyAnalysisInspection? inspection;
  GenerationArtifactFailure? error;
  String? exportedPath;
  bool loading = false;
  bool exporting = false;
  int _epoch = 0;

  Future<void> load(String path) async {
    if (isDisposed || exporting) return;
    final epoch = ++_epoch;
    loading = true;
    inspection = null;
    exportedPath = null;
    error = null;
    notifyListeners();
    try {
      final result = await artifacts.inspectLegacy(path);
      if (isDisposed || epoch != _epoch) return;
      inspection = result;
    } catch (failure) {
      if (isDisposed || epoch != _epoch) return;
      error = failure is GenerationArtifactFailure
          ? failure
          : GenerationArtifactFailure(
              '$failure',
              kind: GenerationArtifactFailureKind.read,
            );
    } finally {
      if (!isDisposed && epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> export(
    GenerationArtifactKind kind,
    Future<String?> Function() chooseDestination,
  ) async {
    final captured = inspection;
    if (isDisposed || loading || exporting || captured == null) return;
    exporting = true;
    error = null;
    exportedPath = null;
    notifyListeners();
    try {
      final destination = await chooseDestination();
      if (isDisposed || destination == null) return;
      await artifacts.repository.exportLegacy(
        captured.snapshot,
        kind,
        destination,
      );
      if (!isDisposed) exportedPath = destination;
    } catch (failure) {
      if (!isDisposed) {
        error = failure is GenerationArtifactFailure
            ? failure
            : GenerationArtifactFailure(
                '$failure',
                kind: GenerationArtifactFailureKind.export,
              );
      }
    } finally {
      if (!isDisposed) {
        exporting = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }
}
