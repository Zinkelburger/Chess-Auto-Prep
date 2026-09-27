import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A document store whose answers the test writes, for owners and widgets
/// that must never touch a real file.
///
/// Each operation takes the next result queued for it. With nothing queued
/// it behaves like the real one: a save whose expected revision is not what
/// [documents] holds is a conflict, and a save that goes through replaces the
/// document and returns its receipt. With [hold] set, every call waits until
/// the test releases it, so a test can look at what an owner shows while a
/// save is still in flight.
final class ScriptedDocumentStore implements PgnDocumentStore {
  /// What [open] answers; a document that is not here is [Absent].
  final documents = <DocumentRef, DocumentRead>{};

  final creates = <CreateResult>[];
  final saves = <SaveResult>[];
  final moves = <MoveResult>[];
  final folderMoves = <FolderMoveResult>[];
  final deletes = <DeleteResult>[];

  /// Every save that was asked for, in the order it was asked.
  final requestedSaves = <SaveRequest>[];

  /// What each deleted document held when it was deleted, which is what the
  /// real store's recovery copy would hold.
  final deleted = <DocumentRef, String>{};

  bool hold = false;

  /// Thrown by the next [save] instead of answering it, for the store
  /// failure that is nobody's typed result — a lock database that will not
  /// open, say.
  Object? throwOnSave;

  /// What a move or delete says became of the training rows.
  RepointResult repoint = const NothingToRepoint();

  final _waiting = <Completer<void>>[];

  /// The file a ref names: every chapter of a course file is that one file
  /// on disk, as the real store sees it.
  DocumentRef _file(DocumentRef ref) =>
      ref.section == null ? ref : DocumentRef(ref.path);

  int get waiting => _waiting.length;

  void releaseNext() => _waiting.removeAt(0).complete();

  /// Lets the newest waiting call answer, ahead of older ones.
  void releaseLast() => _waiting.removeLast().complete();

  void releaseAll() {
    while (_waiting.isNotEmpty) {
      releaseNext();
    }
  }

  @override
  Future<DocumentRead> open(DocumentRef ref) async {
    await _turn();
    return documents[_file(ref)] ?? const Absent();
  }

  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    await _turn();
    final queued = _next(creates);
    if (queued != null) return queued;
    if (documents.containsKey(_file(ref))) return const Collision();
    final revision = scriptedRevision(text);
    documents[_file(ref)] = Opened(text, revision);
    return Created(revision);
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) async {
    requestedSaves.add(SaveRequest(ref, text, expected, scope));
    await _turn();
    final thrown = throwOnSave;
    if (thrown != null) {
      throwOnSave = null;
      throw thrown;
    }
    final queued = _next(saves);
    if (queued != null) return queued;
    if (scope is RestoredVersion && scope.inverse?.secondary != null) {
      final inverse = scope.inverse!;
      final secondary = inverse.secondary!;
      return _pair(
        DocumentEdit(
          ref: ref,
          text: text,
          expected: expected,
          scope: const RestoredVersion(),
        ),
        DocumentEdit(
          ref: DocumentRef(secondary.path),
          text: secondary.before,
          expected: scriptedRevision(secondary.after),
          scope: const RestoredVersion(),
        ),
        '${inverse.id}-undo',
      );
    }
    final before = documents[_file(ref)];
    if (before is! Opened) return const Conflict(null);
    if (before.revision != expected) return Conflict(before.revision);
    final committed = scriptedRevision(text);
    documents[_file(ref)] = Opened(text, committed);
    return Saved(
      Receipt(
        committed: committed,
        before: before.text,
        beforeRevision: before.revision,
      ),
    );
  }

  @override
  Future<SaveResult> savePair(
    DocumentEdit primary,
    DocumentEdit secondary, {
    required String operationId,
  }) async {
    for (final edit in [primary, secondary]) {
      requestedSaves.add(
        SaveRequest(edit.ref, edit.text, edit.expected, edit.scope),
      );
    }
    await _turn();
    final thrown = throwOnSave;
    if (thrown != null) {
      throwOnSave = null;
      throw thrown;
    }
    final queued = _next(saves);
    return queued ?? _pair(primary, secondary, operationId);
  }

  final _pairs = <String, Saved>{};

  SaveResult _pair(DocumentEdit primary, DocumentEdit secondary, String id) {
    final done = _pairs[id];
    if (done != null) {
      final parts = done.receipt.compound!.documents;
      final edits = [primary, secondary];
      for (var i = 0; i < 2; i++) {
        if (parts[i].path != edits[i].ref.path ||
            parts[i].after != edits[i].text ||
            scriptedRevision(parts[i].before) != edits[i].expected) {
          return const SaveRefused('The pair id belongs to another edit.');
        }
      }
      return done;
    }
    if (primary.ref.path == secondary.ref.path) {
      return const SaveRefused('A pair requires two files.');
    }
    final prior = <Opened>[];
    for (final edit in [primary, secondary]) {
      final before = documents[_file(edit.ref)];
      if (before is! Opened) return const Conflict(null);
      if (before.revision != edit.expected) return Conflict(before.revision);
      prior.add(before);
    }
    final compound = CompoundCommit.pair(
      id: id,
      primary: CompoundDocument(
        path: primary.ref.path,
        before: prior[0].text,
        after: primary.text,
      ),
      secondary: CompoundDocument(
        path: secondary.ref.path,
        before: prior[1].text,
        after: secondary.text,
      ),
    );
    for (final edit in [primary, secondary]) {
      documents[_file(edit.ref)] = Opened(
        edit.text,
        scriptedRevision(edit.text),
      );
    }
    return _pairs[id] = Saved(
      Receipt(
        committed: scriptedRevision(primary.text),
        before: prior[0].text,
        beforeRevision: prior[0].revision,
        compound: compound,
        secondaryRef: secondary.ref,
      ),
    );
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
    await _turn();
    final queued = _next(moves);
    if (queued != null) return queued;
    final current = documents[_file(ref)];
    if (current is! Opened) return const Conflict(null);
    if (current.revision != expected) return Conflict(current.revision);
    if (documents.containsKey(destination)) return const Collision();
    documents.remove(ref);
    documents[destination] = current;
    return Moved(current.revision, training: repoint);
  }

  /// Every document under [from] takes the new folder's name at once, as one
  /// rename of the folder does; a name already taken moves nothing.
  @override
  Future<FolderMoveResult> moveFolder(
    String from,
    String to, {
    String? operationId,
  }) async {
    await _turn();
    final queued = _next(folderMoves);
    if (queued != null) return queued;
    final inside = documents.keys
        .where((ref) => p.isWithin(from, ref.path))
        .toList();
    final moved = <DocumentRef, DocumentRead>{};
    for (final ref in inside) {
      final target = DocumentRef(p.join(to, p.relative(ref.path, from: from)));
      if (documents.containsKey(target)) return const FolderNameTaken();
      moved[target] = documents[_file(ref)]!;
    }
    inside.forEach(documents.remove);
    documents.addAll(moved);
    return FolderMoved(
      training: repoint,
      files: Map.unmodifiable({
        for (final entry in moved.entries)
          if (entry.value case Opened(:final revision))
            p.relative(entry.key.path, from: to): revision,
      }),
    );
  }

  @override
  Future<DeleteResult> delete(
    DocumentRef ref, {
    required Revision expected,
    String? operationId,
  }) async {
    await _turn();
    final queued = _next(deletes);
    if (queued != null) return queued;
    final current = documents[_file(ref)];
    if (current is! Opened) return const Conflict(null);
    if (current.revision != expected) return Conflict(current.revision);
    deleted[_file(ref)] = current.text;
    documents.remove(ref);
    return Deleted('${ref.path}.recovered', training: repoint);
  }

  T? _next<T>(List<T> queued) => queued.isEmpty ? null : queued.removeAt(0);

  Future<void> _turn() {
    if (!hold) return Future<void>.value();
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }
}

final class SaveRequest {
  const SaveRequest(this.ref, this.text, this.expected, this.scope);

  final DocumentRef ref;
  final String text;
  final Revision expected;

  /// What the save said it was changing.
  final EditScope scope;
}

/// A revision that two scripted answers about the same text agree on.
Revision scriptedRevision(String text) =>
    Revision(sha256.convert(utf8.encode(text)).toString());
