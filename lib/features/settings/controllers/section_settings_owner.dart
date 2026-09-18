import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/section_configuration.dart';
import '../models/settings_state.dart';
import '../repositories/settings_section_storage.dart';

/// Application-scoped settings owner. Serial field edits retain failed drafts
/// without installing them as the committed runtime configuration.
abstract class SectionSettingsOwner<C extends SectionConfiguration<C>>
    extends ChangeNotifier
    with SafeChangeNotifier {
  SectionSettingsOwner(this._storage, this.defaults);
  final C defaults;
  final SettingsSectionStorage<C> _storage;
  SettingsState<C> _state = const SettingsState();
  Future<void>? _tail;
  Future<void>? _loading;
  SettingsPatch<C>? _failedEdit;
  Object? _failedError;
  final List<SettingsPatch<C>> _pendingEdits = [];

  SettingsState<C> get state => _state;
  C get committed => state.committed ?? defaults;
  C get editing => state.draft ?? committed;

  Future<void> edit(Map<String, Object> fields) {
    if (fields.keys.any((key) => !defaults.values.containsKey(key))) {
      return Future.error(ArgumentError('Unknown settings field'));
    }
    final normalized = editing.withValues({...editing.values, ...fields});
    return _applyQueued(
      SettingsPatch<C>({
        for (final key in fields.keys) key: normalized.values[key]!,
      }),
    );
  }

  void submit(Map<String, Object> fields) {
    if (fields.entries.every(
      (entry) => editing.values[entry.key] == entry.value,
    ))
      return;
    unawaited(edit(fields).catchError((Object _) {}));
  }

  Future<void> resetToDefaults() => edit(defaults.values);

  void _emit(SettingsState<C> value) {
    final committed = value.committed;
    if (committed != null && _pendingEdits.isNotEmpty) {
      var draft = _failedEdit?.apply(committed) ?? committed;
      for (final edit in _pendingEdits) {
        draft = edit.apply(draft);
      }
      value = SettingsState(
        phase: value.phase == SettingsPhase.ready
            ? SettingsPhase.saving
            : value.phase,
        committed: committed,
        draft: draft,
        error: value.error,
      );
    }
    _state = value;
    notifyListeners();
  }

  Future<void> _queue(Future<void> Function() action) {
    if (isDisposed) {
      return Future.error(StateError('Settings owner is disposed'));
    }
    final previous = _tail;
    final settled = Completer<void>();
    _tail = settled.future;
    final run = previous == null
        ? Future<void>.sync(action)
        : previous.then((_) => action());
    unawaited(
      run.then<void>(
        (_) => settled.complete(),
        onError: (Object _, StackTrace _) => settled.complete(),
      ),
    );
    return run;
  }

  Future<void> ensureLoaded() =>
      _loading ?? (state.committed == null ? reload() : Future.value());

  Future<void> reload() {
    final pending = _loading;
    if (pending != null) return pending;
    final run = _queue(() async {
      _emit(
        SettingsState(
          phase: SettingsPhase.loading,
          committed: state.committed,
          draft: state.draft,
        ),
      );
      try {
        final value = await _storage.read();
        _emit(
          SettingsState(
            phase: _failedEdit == null
                ? SettingsPhase.ready
                : SettingsPhase.failed,
            committed: value,
            draft: _failedEdit?.apply(value),
            error: _failedError,
          ),
        );
      } catch (error) {
        _emit(
          SettingsState(
            phase: SettingsPhase.failed,
            committed: state.committed,
            draft: state.draft,
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

  Future<void> _applyQueued(SettingsPatch<C> edit) {
    if (edit.isEmpty) return Future.value();
    if (isDisposed) {
      return Future.error(StateError('Settings owner is disposed'));
    }
    _pendingEdits.add(edit);
    return _queue(() => _apply(edit));
  }

  Future<void> _apply(SettingsPatch<C> edit) async {
    var committed = state.committed;
    var draft = committed == null ? null : edit.apply(committed);
    _emit(
      SettingsState(
        phase: SettingsPhase.saving,
        committed: committed,
        draft: draft,
      ),
    );
    try {
      committed = await _storage.read();
      draft = edit.apply(committed);
      _emit(
        SettingsState(
          phase: SettingsPhase.saving,
          committed: committed,
          draft: draft,
        ),
      );
      await _storage.write(edit);
      final confirmed = await _storage.read();
      if (edit.apply(confirmed) != confirmed) {
        throw StateError('Preferences changed before save confirmation');
      }
      _pendingEdits.remove(edit);
      _failedEdit = _failedEdit?.without(edit.changes.keys);
      if (_failedEdit?.isEmpty ?? true) {
        _failedEdit = null;
        _failedError = null;
      }
      _emit(
        SettingsState(
          phase: _failedEdit == null
              ? SettingsPhase.ready
              : SettingsPhase.failed,
          committed: confirmed,
          draft: _failedEdit?.apply(confirmed),
          error: _failedError,
        ),
      );
    } catch (error) {
      // A multi-key legacy save may have partially committed. Reconcile what
      // was actually stored; retain the edit for an explicit idempotent retry.
      try {
        committed = await _storage.read();
      } catch (_) {}
      _pendingEdits.remove(edit);
      _failedEdit = _failedEdit?.followedBy(edit) ?? edit;
      _failedError = error;
      _emit(
        SettingsState(
          phase: SettingsPhase.failed,
          committed: committed,
          draft: committed == null ? draft : _failedEdit!.apply(committed),
          error: error,
        ),
      );
      rethrow;
    }
  }

  Future<void> retry() =>
      _failedEdit == null ? reload() : _applyQueued(_failedEdit!);
}
