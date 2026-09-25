import 'package:flutter/foundation.dart';

import '../../storage/integrity_report.dart';

/// The report is explicitly a past check, never live authorization to mutate.
/// Closing its dialog ignores late delivery; the reader only releases locks.
final class IntegrityCheck extends ChangeNotifier {
  IntegrityCheck(this.reader);
  final IntegrityReader reader;
  IntegrityReport? report;
  String? problem;
  bool reading = false;
  bool _disposed = false;

  Future<void> refresh() async {
    if (_disposed || reading) return;
    reading = true;
    problem = null;
    notifyListeners();
    try {
      final next = await reader.read();
      if (!_disposed) report = next;
    } on Object {
      if (!_disposed)
        problem =
            'The check could not finish. Retry when storage is available.';
    } finally {
      reading = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
