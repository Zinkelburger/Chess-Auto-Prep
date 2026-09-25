import 'dart:async';

import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';

/// A repertoire listing the test writes, whose timing the test controls:
/// every call waits until the test releases it.
final class ScriptedFiles implements ChapterFiles {
  ScriptedFiles({
    this.listing = const Repertoires([]),
    this.deletedListing = const DeletedChapters([]),
    this.isEmpty,
  });

  RepertoireListing listing;

  /// What the recovery folders hold.
  DeletedListing deletedListing;

  /// Whether a folder has nothing left in it, which the real listing answers
  /// from the disk the store just wrote to. Without it every folder counts as
  /// empty, so a test that asserts a folder went has to say so itself.
  final bool Function(String folder)? isEmpty;

  /// With this set, every call waits until the test releases it.
  bool hold = false;

  /// The folders that were actually taken away, in order.
  final removed = <String>[];

  final _pending = <Completer<void>>[];

  int get pendingCalls => _pending.length;

  /// Lets the oldest waiting call answer.
  void releaseNext() => _pending.removeAt(0).complete();

  /// Lets the newest waiting call answer, ahead of older ones.
  void releaseLast() => _pending.removeLast().complete();

  void releaseAll() {
    while (_pending.isNotEmpty) {
      releaseNext();
    }
  }

  /// How many times the listing has been read, so a test can say that
  /// nothing read it again.
  var listings = 0;

  @override
  Future<RepertoireListing> list() async {
    listings++;
    await _wait();
    return listing;
  }

  /// Explicit substitute for the native whole-readset validation boundary.
  /// Tests may hold it independently from listing/PGN reads.
  Future<RepertoireValidation> Function(Repertoires, Map<String, Revision>)?
  validateWith;

  final additionalValidations = <Map<String, Revision?>>[];

  @override
  Future<RepertoireValidation> validate(
    Repertoires snapshot, {
    required Map<String, Revision> observed,
    Map<String, Revision?> additional = const {},
  }) async {
    additionalValidations.add(Map.unmodifiable(additional));
    return validateWith == null
        ? (identical(snapshot, listing)
              ? const RepertoireCurrent()
              : const RepertoireChanged())
        : validateWith!(snapshot, observed);
  }

  @override
  Future<DeletedListing> deleted() async {
    await _wait();
    return deletedListing;
  }

  @override
  Future<void> removeIfEmpty(String folder) async {
    if (isEmpty?.call(folder) ?? true) removed.add(folder);
  }

  /// The staging folders an import took away, in order.
  final stagingRemoved = <String>[];

  @override
  Future<void> removeStaging(String folder) async {
    stagingRemoved.add(folder);
  }

  Future<void> _wait() {
    if (!hold) return Future<void>.value();
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }
}

ChapterRef ref(String repertoire, String name) => ChapterRef(
  repertoire: repertoire,
  name: name,
  path: '/repertoires/$repertoire/$name.pgn',
);

/// A repertoire folder holding [names], modified now.
RepertoireFolder folder(
  String name,
  List<String> names, {
  DateTime? modified,
}) => RepertoireFolder(
  name: name,
  path: '/repertoires/$name',
  modified: modified ?? DateTime.now(),
  chapters: [for (final chapter in names) ref(name, chapter)],
);
