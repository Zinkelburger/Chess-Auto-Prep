import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/settings/models/app_appearance.dart';
import '../../features/settings/models/settings_state.dart';
import '../../features/settings/repositories/app_settings_repository.dart';

abstract interface class AppearancePreferences {
  Future<AppAppearance> read();
  Future<void> write(AppAppearance value);
}

class SharedPreferencesAppearance implements AppearancePreferences {
  static const key = 'app_appearance';
  @override
  Future<AppAppearance> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.get(key);
    if (raw == null) return AppAppearance.dark;
    for (final value in AppAppearance.values) {
      if (raw == value.name) return value;
    }
    throw const FormatException('Invalid appearance preference');
  }

  @override
  Future<void> write(AppAppearance value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, value.name)) {
      throw StateError('Appearance could not be saved');
    }
  }
}

/// One scalar key with serialized writes and explicit failure/retry. The app
/// renders only the read-back committed value, never an unconfirmed draft.
class PersistedAppearance implements AppearanceRepository {
  PersistedAppearance(this._preferences);
  final AppearancePreferences _preferences;
  final _changes = StreamController<SettingsState<AppAppearance>>.broadcast(
    sync: true,
  );
  SettingsState<AppAppearance> _state = const SettingsState();
  Future<void> _tail = Future.value();
  Future<void>? _loading;
  AppAppearance? _failedEdit;
  @override
  SettingsState<AppAppearance> get state => _state;
  @override
  Stream<SettingsState<AppAppearance>> get changes => _changes.stream;

  void _emit(SettingsState<AppAppearance> state) {
    _state = state;
    _changes.add(state);
  }

  Future<void> _queue(Future<void> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  @override
  Future<void> ensureLoaded() =>
      _loading ??
      (state.phase == SettingsPhase.unloaded ? reload() : Future.value());

  @override
  Future<void> reload() {
    final pending = _loading;
    if (pending != null) return pending;
    final run = _queue(() async {
      _emit(
        SettingsState(phase: SettingsPhase.loading, committed: state.committed),
      );
      try {
        final value = await _preferences.read();
        _failedEdit = null;
        _emit(SettingsState(phase: SettingsPhase.ready, committed: value));
      } catch (error) {
        _emit(
          SettingsState(
            phase: SettingsPhase.failed,
            committed: state.committed,
            draft: _failedEdit,
            error: error,
          ),
        );
        rethrow;
      }
    });
    _loading = run;
    unawaited(
      run.then<void>(
        (_) => _loading = null,
        onError: (Object _, StackTrace _) {
          _loading = null;
        },
      ),
    );
    return run;
  }

  @override
  Future<void> setAppearance(AppAppearance value) => _queue(() async {
    var committed = state.committed;
    _emit(
      SettingsState(
        phase: SettingsPhase.saving,
        committed: committed,
        draft: value,
      ),
    );
    try {
      await _preferences.write(value);
      committed = await _preferences.read();
      if (committed != value) {
        throw StateError('Appearance changed before save confirmation');
      }
      _failedEdit = null;
      _emit(SettingsState(phase: SettingsPhase.ready, committed: committed));
    } catch (error) {
      try {
        committed = await _preferences.read();
      } catch (_) {
        /* Last confirmed value stays available. */
      }
      _failedEdit = value;
      _emit(
        SettingsState(
          phase: SettingsPhase.failed,
          committed: committed,
          draft: value,
          error: error,
        ),
      );
      rethrow;
    }
  });

  @override
  Future<void> retry() =>
      _failedEdit == null ? reload() : setAppearance(_failedEdit!);
}
