import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/chapter_files.dart';
import '../storage/document_repository.dart';

/// Shared repertoire metadata, independent of any mode's search or selection.
/// Successful document mutations invalidate it at the repository boundary.
/// Refreshes coalesce, and a mutation during a read forces another read before
/// the refresh completes. Consumers observe whole committed listings.
final class RepertoireCatalog extends ChangeNotifier {
  RepertoireCatalog({
    required this._files,
    this._documents,
    required this.root,
  }) {
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

  /// The latest admission only; null is an explicit complete refresh. The
  /// cumulative [changes] remains available for the final catalog publication.
  DocumentChange? admittedChange;
  bool reloaded = false;
  final _pendingChanges = <DocumentChange>[];
  bool _manualRefresh = false;
  Future<void>? _reading;
  bool _dirty = false;
  bool _disposed = false;
  bool _stale = true;
  String? _problem;
  int _version = 0;
  int _inputsRevision = 0;

  /// Admission of a committed change or explicit refresh, independent of the
  /// later listing publication. Consumers handle each affected batch once.
  int get inputsRevision => _inputsRevision;

  bool get stale => _stale;
  String? get problem => _problem;
  int get version => _version;

  /// Nested PGNs belong to the top-level repertoire, matching the native
  /// listing's recursive folder inventory even before a refresh completes.
  String? repertoireOf(String path) {
    if (!p.isWithin(root, path)) return null;
    final parts = p.split(p.relative(path, from: root));
    return parts.length > 1 ? p.join(root, parts.first) : root;
  }

  void _changed() {
    final change = _documents?.lastChange;
    if (change == null || !change.touches(root)) return;
    _pendingChanges.add(change);
    admittedChange = change;
    _inputsRevision++;
    unawaited(_refresh());
  }

  Future<void> refresh() {
    _manualRefresh = true;
    admittedChange = null;
    _inputsRevision++;
    return _refresh();
  }

  /// Library commands wait for the repository's refresh, without inventing a
  /// second change. Standalone catalogs (tests or offline tools) reread here.
  Future<void> synchronize() =>
      _documents == null ? refresh() : (_reading ?? Future<void>.value());

  Future<void> _refresh() {
    if (_disposed) return Future<void>.value();
    _dirty = true;
    _stale = true;
    final reading = _reading ??= _read().whenComplete(() => _reading = null);
    changes = List.unmodifiable(_pendingChanges);
    reloaded = _manualRefresh;
    notifyListeners();
    return reading;
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
    final complete = next is Repertoires && next.unreadable.isEmpty;
    if (complete) {
      _listing = next;
      _problem = null;
      _stale = false;
      _version++;
    } else {
      _listing ??= next;
      _stale = true;
      _problem = switch (next) {
        RepertoiresUnreadable(:final detail) => detail,
        Repertoires(:final unreadable) => unreadable.first.detail,
      };
    }
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
