import 'dart:async';

import 'package:shared_preferences_linux/shared_preferences_linux.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Install before any settings load. The Linux/Windows legacy plugins cache
/// failed writes below SharedPreferences.reload(). Give every platform request
/// a fresh backend and serialize requests so unrelated legacy keys survive.
/// This keeps the plugin's existing file format and prefix/filter semantics.
void installFreshDesktopPreferencesStore() {
  final current = SharedPreferencesStorePlatform.instance;
  if (current is SharedPreferencesLinux) {
    SharedPreferencesStorePlatform.instance = FreshDesktopPreferencesStore(
      SharedPreferencesLinux.new,
    );
  } else if (current is SharedPreferencesWindows) {
    SharedPreferencesStorePlatform.instance = FreshDesktopPreferencesStore(
      SharedPreferencesWindows.new,
    );
  }
}

/// A narrow workaround for the locked desktop plugin versions' second cache.
/// No secrets are inspected/logged and no other process transaction is claimed.
class FreshDesktopPreferencesStore extends SharedPreferencesStorePlatform {
  FreshDesktopPreferencesStore(this._create);
  final SharedPreferencesStorePlatform Function() _create;
  Future<void>? _pending;

  Future<T> _run<T>(Future<T> Function(SharedPreferencesStorePlatform) action) {
    final previous = _pending;
    final drained = Completer<void>();
    final result = Completer<T>();
    _pending = drained.future;
    Future<void> run() async {
      try {
        result.complete(await action(_create()));
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        if (identical(_pending, drained.future)) _pending = null;
        drained.complete();
      }
    }

    if (previous == null) {
      scheduleMicrotask(() => unawaited(run()));
    } else {
      unawaited(previous.then((_) => run()));
    }
    return result.future;
  }

  @override
  Future<Map<String, Object>> getAll() => _run((store) => store.getAll());
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => _run((store) => store.getAllWithParameters(parameters));
  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );
  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    final captured = value is List<String> ? List<String>.of(value) : value;
    return _run((store) => store.setValue(valueType, key, captured));
  }

  @override
  Future<bool> remove(String key) => _run((store) => store.remove(key));
  @override
  Future<bool> clear() => _run((store) => store.clear());
  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _run((store) => store.clearWithParameters(parameters));
  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );
}
