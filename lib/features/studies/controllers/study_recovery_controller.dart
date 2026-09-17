import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../repositories/study_recovery_store.dart';
import 'study_controller.dart';

/// Recovery I/O has one coalesced pending checkpoint and one in-flight write.
/// A periodic trailing checkpoint cannot starve during continuous editing.
class StudyRecoveryController extends ChangeNotifier with SafeChangeNotifier {
  StudyRecoveryController({
    required this.study,
    required this._store,
    this.interval = const Duration(seconds: 1),
  }) {
    study.addListener(_changed);
    unawaited(refresh());
  }
  final StudyController study;
  final StudyRecoveryStore _store;
  final Duration interval;
  StudyRecoveryListing listing = StudyRecoveryListing([]);
  Object? readError;
  Object? writeError;
  Object? actionError;
  bool busy = false;
  bool loading = false;
  bool _pending = false;
  bool _stopped = false;
  bool _restoring = false;
  Timer? _timer;
  Future<void>? _writing;

  void _changed() {
    if (_stopped) return;
    _pending = true;
    if (!_restoring && writeError == null) {
      _timer ??= Timer(interval, () {
        _timer = null;
        unawaited(flush().catchError((Object _) {}));
      });
    }
  }

  Future<void> refresh() async {
    if (loading || _stopped) return;
    loading = true;
    notifyListeners();
    try {
      listing = await _store.list();
      readError = null;
    } catch (error) {
      readError = error;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _writing ??= Future<void>.value()
        .then((_) async {
          while (_pending) {
            _pending = false;
            try {
              await _store.write(study.captureWorkspace());
              writeError = null;
            } catch (error) {
              _pending = true;
              writeError = error;
              notifyListeners();
              rethrow;
            }
          }
          notifyListeners();
        })
        .whenComplete(() => _writing = null);
  }

  Future<void> restore(StudyRecoveryEntry entry) async {
    if (busy || _stopped) return;
    busy = true;
    _restoring = true;
    actionError = null;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
    try {
      await _writing;
      await study.restoreWorkspace(entry.snapshot);
      _pending = true;
      await flush(); // A durable new checkpoint precedes resolving the old one.
      await _store.resolve(entry);
      await refresh();
    } catch (error) {
      actionError = error;
    } finally {
      busy = false;
      _restoring = false;
      notifyListeners();
    }
  }

  Future<void> dismiss(StudyRecoveryEntry entry) async {
    if (busy || _stopped) return;
    busy = true;
    actionError = null;
    notifyListeners();
    try {
      await _store.resolve(entry);
      await refresh();
    } catch (error) {
      actionError = error;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> shutdown() async {
    if (_stopped) return;
    _stopped = true;
    study.removeListener(_changed);
    _timer?.cancel();
    _timer = null;
    try {
      await flush();
    } finally {
      await _store.close();
    }
  }

  @override
  void dispose() {
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}
