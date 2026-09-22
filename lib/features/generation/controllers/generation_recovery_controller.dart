import 'package:flutter/foundation.dart';

import '../models/generation_artifacts.dart';
import '../models/generation_recovery.dart';
import '../../../utils/safe_change_notifier.dart';
import '../services/generation_artifacts.dart';

/// One read-only recovery lifetime, with lazy selection and captured exports.
class GenerationRecoveryController extends ChangeNotifier
    with SafeChangeNotifier {
  GenerationRecoveryController(this.artifacts);
  final GenerationArtifacts artifacts;
  GenerationRecoverySources? sources;
  String? chapterPath;
  GenerationRecoveryCatalog? catalog;
  GenerationRecoveryEntry? selected;
  GenerationRecoveryInspection? inspection;
  GenerationArtifactFailure? error;
  String? exportedPath;
  bool loading = false;
  bool exporting = false;
  int _epoch = 0;

  GenerationArtifactFailure _failure(
    Object error,
    GenerationArtifactFailureKind kind,
  ) => error is GenerationArtifactFailure
      ? error
      : GenerationArtifactFailure('$error', kind: kind);

  Future<void> loadSources() async {
    if (isDisposed || exporting) return;
    final epoch = ++_epoch;
    sources = null;
    chapterPath = null;
    catalog = null;
    selected = null;
    inspection = null;
    error = null;
    exportedPath = null;
    loading = true;
    notifyListeners();
    try {
      final result = await artifacts.repository.listRecoverySources();
      if (!isDisposed && epoch == _epoch) sources = result;
    } catch (failure) {
      if (!isDisposed && epoch == _epoch) {
        error = _failure(failure, GenerationArtifactFailureKind.enumerate);
      }
    } finally {
      if (!isDisposed && epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> load(String path) async {
    if (isDisposed || exporting) return;
    final epoch = ++_epoch;
    loading = true;
    chapterPath = path;
    catalog = null;
    selected = null;
    inspection = null;
    exportedPath = null;
    error = null;
    notifyListeners();
    try {
      final result = await artifacts.repository.listRecovery(path);
      if (isDisposed || epoch != _epoch) return;
      catalog = result;
      error = result.error;
      loading = false;
      notifyListeners();
      if (result.entries.isNotEmpty) await select(result.entries.first);
    } catch (failure) {
      if (isDisposed || epoch != _epoch) return;
      error = _failure(failure, GenerationArtifactFailureKind.enumerate);
    } finally {
      if (!isDisposed && epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> select(GenerationRecoveryEntry entry) async {
    if (isDisposed || exporting || catalog?.entries.contains(entry) != true) {
      return;
    }
    final epoch = ++_epoch;
    selected = entry;
    inspection = null;
    exportedPath = null;
    error = catalog?.error;
    loading = true;
    notifyListeners();
    try {
      final result = await artifacts.inspectRecovery(entry);
      if (isDisposed || epoch != _epoch) return;
      inspection = result;
    } catch (failure) {
      if (isDisposed || epoch != _epoch) return;
      error = _failure(failure, GenerationArtifactFailureKind.read);
    } finally {
      if (!isDisposed && epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> export(
    GenerationRecoveryFile file,
    Future<String?> Function() chooseDestination,
  ) async {
    final captured = inspection;
    if (isDisposed ||
        loading ||
        exporting ||
        captured == null ||
        !captured.snapshot.files.contains(file)) {
      return;
    }
    exporting = true;
    error = null;
    exportedPath = null;
    notifyListeners();
    try {
      final destination = await chooseDestination();
      if (isDisposed || destination == null) return;
      await artifacts.repository.exportRecovery(file, destination);
      if (!isDisposed) exportedPath = destination;
    } catch (failure) {
      if (!isDisposed) {
        error = _failure(failure, GenerationArtifactFailureKind.export);
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
