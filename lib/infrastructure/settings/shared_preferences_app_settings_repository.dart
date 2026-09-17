import 'dart:async';
import 'persisted_appearance.dart';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/settings/models/repertoire_books.dart';
import '../../features/settings/models/settings_state.dart';
import '../../features/settings/repositories/app_settings_repository.dart';

/// The persistence port also permits deterministic disk-failure tests.
abstract interface class RepertoireBooksPreferences {
  Future<RepertoireBooks> read();
  Future<void> writeSide(BookSide side, List<String> paths);
}

class SharedPreferencesRepertoireBooks implements RepertoireBooksPreferences {
  static String key(BookSide side) => 'my_repertoire_${side.name}_paths';

  @override
  Future<RepertoireBooks> read() async {
    final prefs = await SharedPreferences.getInstance();
    // SharedPreferences updates its cache even when a write returns false.
    // Only a fresh platform read is evidence of committed settings.
    await prefs.reload();
    List<String> paths(BookSide side) {
      final raw = prefs.get(key(side));
      if (raw == null) return const [];
      if (raw is! List) {
        throw FormatException('Invalid book selections for ${side.name}');
      }
      if (raw.any((value) => value is! String)) {
        throw FormatException('Invalid book path for ${side.name}');
      }
      return raw.cast<String>();
    }

    return RepertoireBooks(
      white: paths(BookSide.white),
      black: paths(BookSide.black),
    );
  }

  @override
  Future<void> writeSide(BookSide side, List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setStringList(key(side), paths)) {
      throw StateError('Book selections could not be saved');
    }
  }
}

class SharedPreferencesAppSettingsRepository implements AppSettingsRepository {
  SharedPreferencesAppSettingsRepository({
    RepertoireBooksPreferences? books,
    AppearancePreferences? appearance,
  }) : repertoireBooks = PersistedRepertoireBooks(
         books ?? SharedPreferencesRepertoireBooks(),
       ),
       appearance = PersistedAppearance(
         appearance ?? SharedPreferencesAppearance(),
       );

  /// Transitional process owner shared by startup and the old Games adapter.
  /// Retire the singleton when those callers receive app-scoped injection.
  static final instance = SharedPreferencesAppSettingsRepository();

  @override
  final PersistedRepertoireBooks repertoireBooks;
  @override
  final PersistedAppearance appearance;
}

typedef _BooksEdit = RepertoireBooks Function(RepertoireBooks current);

/// Serializes field changes against a fresh read. Does not claim an atomic
/// transaction across app processes or across the two legacy preference keys.
class PersistedRepertoireBooks implements RepertoireBooksRepository {
  PersistedRepertoireBooks(this._preferences);
  final RepertoireBooksPreferences _preferences;
  final _changes = StreamController<SettingsState<RepertoireBooks>>.broadcast(
    sync: true,
  );
  SettingsState<RepertoireBooks> _state = const SettingsState();
  Future<void>? _tail;
  Future<void>? _loading;
  _BooksEdit? _failedEdit;

  @override
  SettingsState<RepertoireBooks> get state => _state;
  @override
  Stream<SettingsState<RepertoireBooks>> get changes => _changes.stream;

  void _emit(SettingsState<RepertoireBooks> state) {
    _state = state;
    _changes.add(state);
  }

  Future<void> _queue(Future<void> Function() action) {
    final previous = _tail;
    final completion = Completer<void>();
    final drained = Completer<void>();
    // Reserve before invoking any listener. A listener may enqueue an edit.
    _tail = drained.future;
    Future<void> run() async {
      try {
        await action();
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        if (identical(_tail, drained.future)) _tail = null;
        drained.complete();
      }
    }

    if (previous == null) {
      scheduleMicrotask(() => unawaited(run()));
    } else {
      unawaited(previous.then((_) => run()));
    }
    return completion.future;
  }

  @override
  Future<void> ensureLoaded() =>
      state.committed != null ? Future.value() : reload();

  @override
  Future<void> reload() {
    final pending = _loading;
    if (pending != null) return pending;
    final completion = Completer<void>();
    _loading = completion.future;
    unawaited(
      _queue(() async {
        _emit(
          SettingsState(
            phase: SettingsPhase.loading,
            committed: state.committed,
          ),
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
              error: error,
            ),
          );
          rethrow;
        }
      }).then(
        (_) {
          _loading = null;
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          _loading = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  Future<void> _edit(_BooksEdit edit) => _queue(() async {
    RepertoireBooks? draft;
    var committed = state.committed;
    _emit(SettingsState(phase: SettingsPhase.saving, committed: committed));
    try {
      committed = await _preferences.read();
      draft = edit(committed);
      _emit(
        SettingsState(
          phase: SettingsPhase.saving,
          committed: committed,
          draft: draft,
        ),
      );
      for (final side in BookSide.values) {
        final current = committed!;
        draft = edit(current);
        if (current.withSide(side, draft.forSide(side)) == current) continue;
        await _preferences.writeSide(side, draft.forSide(side));
        committed = await _preferences.read();
        if (committed.withSide(side, draft.forSide(side)) != committed) {
          throw StateError('Book selections changed before save confirmation');
        }
        _emit(
          SettingsState(
            phase: SettingsPhase.saving,
            committed: committed,
            draft: draft,
          ),
        );
      }
      _failedEdit = null;
      _emit(SettingsState(phase: SettingsPhase.ready, committed: committed));
    } catch (error) {
      // A platform error can follow a real commit. Re-read instead of
      // asserting that the old value is still saved or rolling it back.
      try {
        committed = await _preferences.read();
      } catch (_) {
        /* Keep the last confirmed value. */
      }
      _failedEdit = edit;
      _emit(
        SettingsState(
          phase: SettingsPhase.failed,
          committed: committed,
          draft: draft,
          error: error,
        ),
      );
      rethrow;
    }
  });

  @override
  Future<void> setPaths(BookSide side, List<String> paths) {
    final captured = List<String>.of(paths);
    return _edit((current) => current.withSide(side, captured));
  }

  @override
  Future<void> addPath(BookSide side, String path) => _edit(
    (current) => current.withSide(side, [...current.forSide(side), path]),
  );
  @override
  Future<void> removePath(BookSide side, String path) => _edit(
    (current) => current.withSide(
      side,
      current.forSide(side).where((value) => value != path),
    ),
  );

  @override
  Future<void> relocate({required String from, required String to}) =>
      _edit((current) {
        Iterable<String> move(List<String> paths) => paths.map(
          (path) => p.equals(path, from)
              ? to
              : p.isWithin(from, path)
              ? p.join(to, p.relative(path, from: from))
              : path,
        );
        return RepertoireBooks(
          white: move(current.white),
          black: move(current.black),
        );
      });

  @override
  Future<void> retry() {
    final edit = _failedEdit;
    return edit == null ? reload() : _edit(edit);
  }
}
