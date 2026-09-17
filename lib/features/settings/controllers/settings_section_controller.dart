import 'dart:async';

import '../models/settings_state.dart';
import '../models/section_configuration.dart';
import '../repositories/settings_section_storage.dart';

/// Serial field edits preserve changes from another panel and expose failed
/// drafts without installing them as the configuration of a training sitting.
class SettingsSectionController<C extends SectionConfiguration<C>> {
  SettingsSectionController(this._storage);
  final SettingsSectionStorage<C> _storage;
  final _changes = StreamController<SettingsState<C>>.broadcast(sync: true);
  SettingsState<C> _state = const SettingsState();
  Future<void>? _tail;
  Future<void>? _loading;
  SettingsPatch<C>? _failedEdit;
  Object? _failedError;
  bool _disposed = false;
  final List<SettingsPatch<C>> _pendingEdits = [];

  SettingsState<C> get state => _state;
  Stream<SettingsState<C>> get changes => _changes.stream;

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
    if (!_disposed) _changes.add(value);
  }

  Future<void> _queue(Future<void> Function() action) {
    if (_disposed) {
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

  Future<void> apply(SettingsPatch<C> edit) {
    if (edit.isEmpty) return Future.value();
    if (_disposed) {
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

  Future<void> retry() => _failedEdit == null ? reload() : apply(_failedEdit!);

  void dispose() {
    _disposed = true;
    unawaited((_tail ?? Future<void>.value()).then((_) => _changes.close()));
  }
}
