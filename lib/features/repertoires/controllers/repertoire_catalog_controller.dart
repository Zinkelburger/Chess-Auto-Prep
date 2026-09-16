import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/repertoire_catalog_state.dart';
import '../models/repertoire_creation.dart';
import '../models/repertoire_metadata.dart';
import '../models/repertoire_recovery_required.dart';
import '../repositories/repertoire_catalog_repository.dart';

/// App startup must supply the implementation. Tests override the same boundary.
final repertoireCatalogRepositoryProvider =
    Provider<RepertoireCatalogRepository>(
      (ref) =>
          throw StateError('Repertoire catalog repository was not injected'),
      retry: (count, error) => null,
    );

final repertoireCatalogProvider = NotifierProvider.autoDispose
    .family<RepertoireCatalogController, RepertoireCatalogState, bool>(
      RepertoireCatalogController.new,
      retry: (count, error) => null,
    );

/// One presentation owner per catalog kind. Mutations reject overlap, never
/// retry implicitly, and survive route/listener changes until their commit ends.
class RepertoireCatalogController extends Notifier<RepertoireCatalogState> {
  RepertoireCatalogController(this.includeStudies);

  final bool includeStudies;
  late RepertoireCatalogRepository _repository;
  int _generation = 0;
  Future<void>? _loading;

  @override
  RepertoireCatalogState build() {
    _repository = ref.watch(repertoireCatalogRepositoryProvider);
    final generation = ++_generation;
    _loading = null;
    ref.onDispose(() => _generation++);
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) unawaited(refresh());
    });
    return RepertoireCatalogState(loading: true);
  }

  /// Coalesce repeated refreshes. A mutation invalidates any older read.
  Future<void> refresh() {
    if (!ref.mounted || state.busy) return Future.value();
    final pending = _loading;
    if (pending != null) return pending;
    // Install the coalescing future before calling the adapter: an adapter
    // may throw synchronously before returning a Future. Such a failure must
    // not leave a completed future cached and prevent explicit retry.
    final completion = Completer<void>();
    _loading = completion.future;
    unawaited(
      _load().then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final repository = _repository;
    state = RepertoireCatalogState(
      repertoires: state.repertoires,
      studies: state.studies,
      loading: true,
      actionError: state.actionError,
    );
    try {
      final results = await Future.wait([
        repository.listRepertoires(),
        if (includeStudies) repository.listStudies(),
      ]);
      if (!ref.mounted || generation != _generation) return;
      List<RepertoireMetadata> sorted(List<RepertoireMetadata> values) =>
          [...values]..sort((a, b) => b.lastModified.compareTo(a.lastModified));
      state = RepertoireCatalogState(
        repertoires: sorted(results.first),
        studies: includeStudies ? sorted(results.last) : const [],
        actionError: state.actionError is RepertoireRecoveryRequired
            ? null
            : state.actionError,
      );
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = RepertoireCatalogState(
        repertoires: state.repertoires,
        studies: state.studies,
        loadError: error,
        actionError: state.actionError,
      );
    } finally {
      if (generation == _generation) _loading = null;
    }
  }

  Future<RepertoireCreationResult> create(CreateRepertoire request) =>
      _mutate(CatalogAction.create, (repository) => repository.create(request));

  Future<void> rename(RepertoireMetadata repertoire, String name) => _mutate(
    CatalogAction.rename,
    (repository) => repository.rename(repertoire, name),
  );

  Future<void> moveToRecovery(RepertoireMetadata repertoire) => _mutate(
    CatalogAction.moveToRecovery,
    (repository) => repository.moveToRecovery(repertoire),
  );

  Future<T> _mutate<T>(
    CatalogAction action,
    Future<T> Function(RepertoireCatalogRepository) commit,
  ) async {
    if (!ref.mounted) throw StateError('Catalog is closed');
    if (state.busy) throw StateError('A catalog action is already running');
    final keepAlive = ref.keepAlive();
    final generation = ++_generation;
    _loading = null;
    state = RepertoireCatalogState(
      repertoires: state.repertoires,
      studies: state.studies,
      action: action,
    );
    try {
      final result = await commit(_repository);
      if (ref.mounted && generation == _generation) {
        state = RepertoireCatalogState(
          repertoires: state.repertoires,
          studies: state.studies,
        );
        // A refresh failure cannot turn a confirmed commit into a failed
        // mutation that a dialog might replay. It has its own retry state.
        await refresh();
      }
      return result;
    } catch (error) {
      if (ref.mounted && generation == _generation) {
        state = RepertoireCatalogState(
          repertoires: state.repertoires,
          studies: state.studies,
          actionError: error,
        );
      }
      rethrow;
    } finally {
      keepAlive.close();
    }
  }
}
