import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/chapter_files.dart';
import '../storage/document_repository.dart';

/// Shared repertoire metadata, independent of any mode's search or selection.
/// Successful document mutations invalidate it at the repository boundary.
/// Refreshes coalesce, and a mutation during a read forces another read before
/// the refresh completes. Consumers observe whole committed listings.
final class RepertoireCatalog extends ChangeNotifier {
  RepertoireCatalog({
    required ChapterFiles files,
    DocumentRepository? documents,
    required this.root,
  }) : _files = files,
       _documents = documents {
    _documents?.addListener(_changed);
  }

  final ChapterFiles _files;
  final DocumentRepository? _documents;
  final String root;
  RepertoireListing? _listing;
  RepertoireListing? get listing => _listing;
  List<RepertoireFolder> get repertoires => switch (_listing) {
    Repertoires(:final folders) => folders,
    _ => const [],
  };
  List<DocumentChange> changes = const [];
  bool reloaded = false;
  final _pendingChanges = <DocumentChange>[];
  bool _manualRefresh = false;
  Future<void>? _reading;
  bool _dirty = false;
  bool _disposed = false;

  void _changed() {
    final change = _documents?.lastChange;
    if (change == null || !change.touches(root)) return;
    _pendingChanges.add(change);
    unawaited(_refresh());
  }

  Future<void> refresh() {
    _manualRefresh = true;
    return _refresh();
  }

  /// Library commands wait for the repository's refresh, without inventing a
  /// second change. Standalone catalogs (tests or offline tools) reread here.
  Future<void> synchronize() =>
      _documents == null ? refresh() : (_reading ?? Future<void>.value());

  Future<void> _refresh() {
    if (_disposed) return Future<void>.value();
    _dirty = true;
    return _reading ??= _read().whenComplete(() => _reading = null);
  }

  Future<void> _read() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      final RepertoireListing next;
      try {
        next = await _files.list();
      } on Object catch (error) {
        if (_disposed) return;
        if (_dirty) continue;
        _publish(RepertoiresUnreadable('$error'));
        return;
      }
      if (_disposed) return;
      if (_dirty) continue;
      _publish(next);
    }
  }

  void _publish(RepertoireListing next) {
    _listing = next;
    changes = List.unmodifiable(_pendingChanges);
    reloaded = _manualRefresh;
    _pendingChanges.clear();
    _manualRefresh = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _documents?.removeListener(_changed);
    super.dispose();
  }
}
