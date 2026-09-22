import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../utils/safe_change_notifier.dart';
import '../models/repertoire_catalog_state.dart';
import '../models/repertoire_creation.dart';
import '../models/repertoire_metadata.dart';
import '../models/repertoire_recovery_required.dart';
import '../repositories/repertoire_catalog_repository.dart';

/// Read state for one of the two fixed catalog views, owned by the controller.
class _CatalogView {
  RepertoireCatalogState state = RepertoireCatalogState(loading: true);
  Future<void>? pending;
  int revision = 0;
  bool requested = false;

  void status({
    bool loading = false,
    Object? loadError,
    CatalogAction? action,
    Object? actionError,
  }) {
    state = RepertoireCatalogState(
      repertoires: state.repertoires,
      studies: state.studies,
      recovery: state.recovery,
      loading: loading,
      loadError: loadError,
      action: action,
      actionError: actionError,
    );
  }
}

/// App-owned catalog reads and mutations. Route changes cannot cancel a commit;
/// library and trainer reads remain independent, while mutations reject overlap.
class RepertoireCatalogController extends ChangeNotifier
    with SafeChangeNotifier {
  RepertoireCatalogController(this._repository);
  final RepertoireCatalogRepository _repository;
  final _library = _CatalogView(), _trainer = _CatalogView();
  _CatalogView _view(bool includeStudies) =>
      includeStudies ? _trainer : _library;
  RepertoireCatalogState snapshot({bool includeStudies = false}) =>
      _view(includeStudies).state;
  bool get supportsRecovery => _repository.supportsRecovery;
  bool get busy => _library.state.busy || _trainer.state.busy;

  Future<void> refresh({bool includeStudies = false}) {
    if (isDisposed) return Future.value();
    final view = _view(includeStudies)..requested = true;
    if (busy) return Future.value();
    if (view.pending case final pending?) return pending;
    // Reserve before calling an adapter that may throw synchronously.
    final completion = Completer<void>();
    view.pending = completion.future;
    unawaited(
      _load(
        view,
        includeStudies,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<void> _load(_CatalogView view, bool includeStudies) async {
    final revision = ++view.revision;
    view.status(loading: true, actionError: view.state.actionError);
    notifyListeners();
    try {
      final results = await Future.wait([
        _repository.listRepertoires(),
        if (includeStudies) _repository.listStudies(),
      ]);
      final recovery = await _repository.listRecovery();
      if (isDisposed || revision != view.revision) return;
      List<RepertoireMetadata> sorted(List<RepertoireMetadata> values) =>
          [...values]..sort((a, b) => b.lastModified.compareTo(a.lastModified));
      view.state = RepertoireCatalogState(
        repertoires: sorted(results.first),
        studies: includeStudies ? sorted(results.last) : const [],
        recovery: recovery,
        actionError: view.state.actionError is RepertoireRecoveryRequired
            ? null
            : view.state.actionError,
      );
    } catch (error) {
      if (isDisposed || revision != view.revision) return;
      view.status(loadError: error, actionError: view.state.actionError);
    } finally {
      if (!isDisposed && revision == view.revision) {
        view.pending = null;
        notifyListeners();
      }
    }
  }

  Future<RepertoireCreationResult> create(
    CreateRepertoire request, {
    bool includeStudies = false,
  }) => _mutate(
    includeStudies,
    CatalogAction.create,
    () => _repository.create(request),
  );
  Future<void> rename(
    RepertoireMetadata repertoire,
    String name, {
    bool includeStudies = false,
  }) => _mutate(
    includeStudies,
    CatalogAction.rename,
    () => _repository.rename(repertoire, name),
  );
  Future<void> moveToRecovery(
    RepertoireMetadata repertoire, {
    bool includeStudies = false,
  }) => _mutate(
    includeStudies,
    CatalogAction.moveToRecovery,
    () => _repository.moveToRecovery(repertoire),
  );
  Future<void> restore(
    String id, {
    String? name,
    bool includeStudies = false,
  }) => _mutate(
    includeStudies,
    CatalogAction.restore,
    () => _repository.restore(id, name: name),
  );

  Future<T> _mutate<T>(
    bool includeStudies,
    CatalogAction action,
    Future<T> Function() commit,
  ) async {
    if (isDisposed) throw StateError('Catalog is closed');
    if (busy) throw StateError('A catalog action is already running');
    final active = _view(includeStudies)..requested = true;
    for (final view in [_library, _trainer]) {
      view.revision++;
      view.pending = null;
      if (view.requested) {
        view.status(
          loadError: view.state.loadError,
          actionError: view.state.actionError,
        );
      }
    }
    active.status(action: action);
    notifyListeners();
    try {
      final result = await commit();
      if (!isDisposed) {
        active.status();
        // Read failures remain read failures; never replay a confirmed write.
        await Future.wait([
          if (_library.requested) refresh(),
          if (_trainer.requested) refresh(includeStudies: true),
        ]);
      }
      return result;
    } catch (error) {
      if (!isDisposed) {
        active.status(actionError: error);
        notifyListeners();
        // The opposite requested view must finish any read invalidated by this write.
        final other = _view(!includeStudies);
        if (other.requested) {
          await refresh(includeStudies: !includeStudies);
        }
      }
      rethrow;
    }
  }
}
