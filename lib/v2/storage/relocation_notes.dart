/// The one thing a relocation cannot do in a single step.
///
/// Moving a chapter is a rename on disk; the training rows that name it are a
/// rewrite of four other files. A machine that stops between them would leave
/// the rows pointing at a name nothing answers to, and the user's schedule,
/// streaks and answers for that chapter would look like another chapter's.
///
/// So a note is written down before the rename and taken away after the rows
/// are rewritten, and whichever relocation comes next finishes the notes it
/// finds before starting its own. One file per move, because two moves can be
/// owed at once and neither may write over the other's note.
///
/// A note carries the native identity of the thing being moved, not just the
/// two paths, because a machine can also stop *before* the rename: then the
/// chapter is still at the old path and rewriting the rows to the new one
/// would point them at a file that never existed. [observeMove] is what tells
/// the two apart, the way the old app tells them apart in
/// `repertoire_directory_mutations.dart`.
///
/// The notes live in Support, next to the kept versions: this is the app's
/// bookkeeping, not something to appear in a folder the user syncs.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'document_ref.dart';
import 'training_records.dart';

/// The training rows' half of a relocation, which is a move's second write.
///
/// One owner for the pair, so the note and the rewrite cannot drift apart:
/// the caller mints a name for the move, records the note before the rename,
/// and asks for the rewrite afterwards; the note goes away only once the rows
/// owe nothing. [finishOwed] is what the next relocation calls to make good
/// on the notes an earlier one left.
final class RelocationNotes {
  const RelocationNotes({
    required PendingRepoints notes,
    required TrainingRecords records,
  }) : _notes = notes,
       _records = records;

  final PendingRepoints _notes;
  final TrainingRecords _records;

  /// Writes down that [from] is about to become [to], under the name [note].
  Future<void> record(
    String note, {
    required String from,
    required String to,
    required String identity,
    required bool folder,
  }) => _notes.record(
    note,
    from: from,
    to: to,
    identity: identity,
    folder: folder,
  );

  /// Takes away the note [note] alone. A move that was refused, or that never
  /// got as far as writing its note, leaves nothing behind for the next one
  /// to make good on.
  Future<void> discard(String note) => _notes.discard(note);

  /// Rewrites the rows that named [from] and, once they owe nothing, takes
  /// [note] away.
  Future<RepointResult> repoint(
    String note,
    DocumentRef from,
    DocumentRef to,
  ) async {
    final result = await _records.repoint(from, to);
    if (_settled(result)) await _notes.discard(note);
    return result;
  }

  /// Finishes the rows every move that stopped half way still owes.
  Future<void> finishOwed() async {
    for (final move in await _notes.read()) {
      await _finish(move);
    }
  }

  /// What one note is worth, which the disk decides ([observeMove]) rather
  /// than the note alone: a machine that stopped before the rename left the
  /// chapter at the old path, and rewriting the rows to the new one would
  /// point a year of reviews at a file that never existed.
  Future<void> _finish(UnfinishedMove move) async {
    switch (await observeMove(move)) {
      case MoveLanded():
        final result = await repoint(
          move.id,
          DocumentRef(move.from),
          DocumentRef(move.to),
        );
        if (!_settled(result)) {
          log.w('finish the training rows left behind by moving ${move.from}');
        }
      case MoveNeverHappened():
        await _notes.discard(move.id);
      case MoveUnclear(:final detail):
        log.e('finish the move of ${move.from}', detail);
    }
  }
}

/// Whether the training rows still owe this move anything.
bool _settled(RepointResult result) =>
    result is Repointed || result is NothingToRepoint;

/// A move that has happened, or was about to, and whose training rows may not
/// have been rewritten yet.
final class UnfinishedMove {
  const UnfinishedMove({
    required this.id,
    required this.from,
    required this.to,
    required this.identity,
    required this.folder,
  });

  /// The note's own name, which is what [PendingRepoints.discard] takes.
  final String id;

  final String from;
  final String to;

  /// The native identity of the file or folder being moved, observed before
  /// the rename. A rename keeps it; a new file at either path does not have
  /// it.
  final String identity;

  /// Whether the two paths name folders rather than documents.
  final bool folder;

  Map<String, Object?> toJson() => {
    'from': from,
    'to': to,
    'identity': identity,
    'folder': folder,
  };
}

/// The name a note is filed under. The caller mints it before the move so it
/// can take the note away again whatever happens.
String newMoveNote() =>
    '${DateTime.now().microsecondsSinceEpoch}-'
    '${Random.secure().nextInt(1 << 32).toRadixString(16)}';

final class PendingRepoints {
  const PendingRepoints(this.support);

  /// The Support folder itself; the notes are one folder inside it.
  final Directory support;

  Directory get _folder => Directory(p.join(support.path, _folderName));

  /// Writes down that [from] is about to become [to]. Throws, like the rest
  /// of a mutation's preparation, when it cannot be written: a move whose
  /// second half could be lost without trace does not start.
  Future<void> record(
    String id, {
    required String from,
    required String to,
    required String identity,
    required bool folder,
  }) async {
    await _folder.create(recursive: true);
    final move = UnfinishedMove(
      id: id,
      from: from,
      to: to,
      identity: identity,
      folder: folder,
    );
    await replaceFile(_pathOf(id), utf8.encode(jsonEncode(move.toJson())));
  }

  /// Takes away the one note [id] names, the rows it describes now naming
  /// what they should. A note that is not there is nothing to take away.
  Future<void> discard(String id) async {
    try {
      final file = File(_pathOf(id));
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      log.w('take away the note at ${_pathOf(id)}', error);
    }
  }

  /// Every move whose training rows are still owed, oldest first. A note
  /// nothing can read is left where it is and left out: it is a file this app
  /// wrote, so a reader that cannot make sense of it has no business
  /// rewriting a schedule on its word.
  Future<List<UnfinishedMove>> read() async {
    if (!await _folder.exists()) return const [];
    final names = <String>[];
    try {
      await for (final entry in _folder.list()) {
        if (entry is File && p.extension(entry.path) == '.json') {
          names.add(p.basenameWithoutExtension(entry.path));
        }
      }
    } on FileSystemException catch (error) {
      log.e('list the unfinished moves in ${_folder.path}', error);
      return const [];
    }
    names.sort();
    final moves = <UnfinishedMove>[];
    for (final name in names) {
      final move = await _readOne(name);
      if (move != null) moves.add(move);
    }
    return moves;
  }

  Future<UnfinishedMove?> _readOne(String id) async {
    try {
      final json = jsonDecode(await File(_pathOf(id)).readAsString());
      if (json is! Map<String, Object?>) return null;
      final from = json['from'];
      final to = json['to'];
      final identity = json['identity'];
      final folder = json['folder'];
      if (from is! String ||
          to is! String ||
          identity is! String ||
          folder is! bool) {
        return null;
      }
      return UnfinishedMove(
        id: id,
        from: from,
        to: to,
        identity: identity,
        folder: folder,
      );
    } on Object catch (error) {
      log.e('read the note at ${_pathOf(id)}', error);
      return null;
    }
  }

  String _pathOf(String id) => p.join(_folder.path, '$id.json');
}

const _folderName = 'unfinished-moves';

/// What the disk says happened to [move], which decides what its training
/// rows should name.
Future<MoveVerdict> observeMove(UnfinishedMove move) async {
  try {
    final from = await _identityOf(move.from, move.folder);
    final to = await _identityOf(move.to, move.folder);
    if (to.identity == move.identity && from.status == _missing) {
      return const MoveLanded();
    }
    if (from.identity == move.identity) return const MoveNeverHappened();
    return MoveUnclear('neither ${move.from} nor ${move.to} is it any more');
  } on Object catch (error) {
    return MoveUnclear('${move.to} could not be looked at: $error');
  }
}

sealed class MoveVerdict {
  const MoveVerdict();
}

/// The new path is the thing the note describes and the old path is empty:
/// the rename happened, so the rows follow it.
final class MoveLanded extends MoveVerdict {
  const MoveLanded();
}

/// The thing is still at the old path, so the rename never happened and the
/// rows are already naming the right file.
final class MoveNeverHappened extends MoveVerdict {
  const MoveNeverHappened();
}

/// Neither path holds it, so nobody can say which name the rows should
/// carry. The note stays; a schedule is not rewritten on a guess.
final class MoveUnclear extends MoveVerdict {
  const MoveUnclear(this.detail);

  /// For the log; nothing is shown to the user for a note.
  final String detail;
}

Future<({int status, String? identity})> _identityOf(
  String path,
  bool folder,
) async {
  if (folder) return observeDirectory(path);
  final observed = await observeFile(path);
  return (status: observed.status, identity: observed.identity);
}

/// The status a native observation reports for a path with nothing at it.
const _missing = 1;
