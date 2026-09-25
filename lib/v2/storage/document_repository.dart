import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'document_ref.dart';
import 'edit_scope.dart';
import 'pgn_document_store.dart';
import 'pending_writes.dart';

enum DocumentChangeKind { created, saved, moved, deleted }

/// A committed change, published only after the storage transaction finishes.
/// A relocation names both sides; a save names one path. UI busy/search state
/// never enters this contract.
final class DocumentChange {
  const DocumentChange(
    this.path, {
    required this.kind,
    this.movedTo,
    this.folder = false,
    this.revision,
  });
  final DocumentChangeKind kind;
  final String path;
  final String? movedTo;
  final bool folder;

  /// Native commit proof when this event has one. Owners may preserve live
  /// work only after adopting this exact receipt, not merely its path.
  final Revision? revision;

  bool touches(String root) =>
      path == root ||
      p.isWithin(root, path) ||
      (folder && p.isWithin(path, root)) ||
      (movedTo != null &&
          (movedTo == root ||
              p.isWithin(root, movedTo!) ||
              (folder && p.isWithin(movedTo!, root))));
}

/// The application's observable document boundary. All document writers use
/// this instance, so imports, autosave, generation and library commands have
/// the same publication semantics. The adapter owns filesystem safety.
final class DocumentRepository extends ChangeNotifier
    implements PgnDocumentStore {
  DocumentRepository(this._store);
  final PgnDocumentStore _store;
  PendingWrites? pendingWrites;

  Future<T> _write<T>(String path, Future<T> work) =>
      pendingWrites?.track(path, work, label: 'Document') ?? work;
  DocumentChange? _lastChange;
  DocumentChange? get lastChange => _lastChange;
  bool _disposed = false;

  void _committed(DocumentChange change) {
    if (_disposed) return;
    _lastChange = change;
    notifyListeners();
  }

  @override
  Future<DocumentRead> open(DocumentRef ref) => _store.open(ref);

  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    final result = await _write(ref.path, _store.create(ref, text));
    if (result is Created)
      _committed(DocumentChange(ref.path, kind: DocumentChangeKind.created));
    return result;
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) async {
    final result = await _write(
      ref.path,
      _store.save(ref, text, expected: expected, scope: scope),
    );
    if (result is Saved) {
      _committed(
        DocumentChange(
          ref.path,
          kind: DocumentChangeKind.saved,
          revision: result.receipt.committed,
        ),
      );
      final secondary = result.receipt.secondaryRef;
      if (secondary != null) {
        _committed(
          DocumentChange(secondary.path, kind: DocumentChangeKind.saved),
        );
      }
    }
    return result;
  }

  @override
  Future<SaveResult> savePair(
    DocumentEdit primary,
    DocumentEdit secondary, {
    required String operationId,
  }) async {
    final result = await _write(
      primary.ref.path,
      _write(
        secondary.ref.path,
        _store.savePair(primary, secondary, operationId: operationId),
      ),
    );
    if (result is Saved) {
      for (final edit in [primary, secondary]) {
        _committed(
          DocumentChange(
            edit.ref.path,
            kind: DocumentChangeKind.saved,
            revision: identical(edit, primary)
                ? result.receipt.committed
                : null,
          ),
        );
      }
    }
    return result;
  }

  @override
  Future<MoveResult> rename(
    DocumentRef ref,
    String name, {
    required Revision expected,
    String? operationId,
  }) => move(
    ref,
    DocumentRef(p.join(p.dirname(ref.path), name)),
    expected: expected,
    operationId: operationId,
  );

  @override
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
    String? operationId,
  }) async {
    final result = await _write(
      ref.path,
      _store.move(
        ref,
        destination,
        expected: expected,
        operationId: operationId,
      ),
    );
    if (result is Moved)
      _committed(
        DocumentChange(
          ref.path,
          kind: DocumentChangeKind.moved,
          movedTo: destination.path,
        ),
      );
    return result;
  }

  @override
  Future<FolderMoveResult> moveFolder(
    String from,
    String to, {
    String? operationId,
  }) async {
    final result = await _write(
      from,
      _store.moveFolder(from, to, operationId: operationId),
    );
    if (result is FolderMoved)
      _committed(
        DocumentChange(
          from,
          kind: DocumentChangeKind.moved,
          movedTo: to,
          folder: true,
        ),
      );
    return result;
  }

  @override
  Future<DeleteResult> delete(
    DocumentRef ref, {
    required Revision expected,
    String? operationId,
  }) async {
    final result = await _write(
      ref.path,
      _store.delete(ref, expected: expected, operationId: operationId),
    );
    if (result is Deleted)
      _committed(DocumentChange(ref.path, kind: DocumentChangeKind.deleted));
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
