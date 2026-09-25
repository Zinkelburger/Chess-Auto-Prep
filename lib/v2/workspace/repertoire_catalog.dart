import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/chapter_files.dart';
import '../storage/document_repository.dart';

/// Shared repertoire metadata, independent of any mode's search or selection.
/// Successful document mutations invalidate it at the repository boundary.
/// Refreshes coalesce, and a mutation during a read forces another read before
/// the refresh completes.
///
/// A listing that could not read some folders is still the listing: the
/// readable repertoires are shown and usable, and the unreadable ones are
/// named beside them. A root that cannot be listed at all keeps the
/// previous listing on screen, so a failed read never blanks the panel.
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

  /// The change that last bumped [inputsRevision]; null after an explicit
  /// refresh, which may have changed anything.
  DocumentChange? admittedChange;
  bool reloaded = false;
  final _pendingChanges = <DocumentChange>[];
  bool _manualRefresh = false;
  Future<void>? _reading;
  bool _dirty = false;
  bool _disposed = false;
  int _inputsRevision = 0;

  /// Counts committed changes and explicit refreshes as they happen, before
  /// the listing is read again, so a consumer handles each one once.
  int get inputsRevision => _inputsRevision;

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
    // A root that cannot be listed keeps the repertoires already shown; with
    // none shown, the failure is what there is to say.
    if (next is Repertoires || repertoires.isEmpty) _listing = next;
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
