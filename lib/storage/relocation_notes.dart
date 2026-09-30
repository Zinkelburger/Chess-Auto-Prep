/// What older builds left of a relocation that stopped half way.
///
/// Moving a chapter is a rename on disk; the training rows that name it are a
/// rewrite of four other files. Older builds wrote a note in
/// `Support/unfinished-moves/<id>.json` before the rename and took it away
/// once the rows were rewritten; this build journals moves in
/// `relocation-writes/` and only reads these notes, finishing each one it
/// finds so a machine that stopped between the two halves does not leave the
/// user's schedule, streaks and answers pointing at a name nothing answers to.
///
/// A note carries the native identity of the thing being moved, not just the
/// two paths, because a machine can also stop *before* the rename: then the
/// chapter is still at the old path and rewriting the rows to the new one
/// would point them at a file that never existed. [observeMove] is what tells
/// the two apart, the way the old app tells them apart in
/// `repertoire_directory_mutations.dart`.
library;

import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'document_ref.dart';
import 'journal_records.dart';
import 'recovery_files.dart';
import 'recovery_ledger.dart';
import 'recovery_quarantine.dart';
import 'training_records.dart';

/// Drains the notes older builds left: a move that landed has its training
/// rows follow it, one that never happened is forgotten, and one nobody can
/// make sense of is set aside. [finishOwed] is what the access guard calls.
final class RelocationNotes {
  RelocationNotes({
    required this.documents,
    required Directory support,
    this._synchronize = syncDirectory,
  }) : support = canonicalRecoveryRoot(support);

  /// The folder under Support the notes are in.
  static const journal = 'unfinished-moves';

  final Directory documents;

  /// The Support folder itself; the notes are one folder inside it.
  final Directory support;
  final Future<void> Function(String) _synchronize;

  /// Finishes the rows every move that stopped half way still owes. A note
  /// that cannot be finished is set aside and logged; the others still run.
  /// One that stopped for a passing reason is owed to a later pass; it
  /// guards nothing, since its rename already happened or never will.
  Future<void> finishOwed() async {
    final ledger = RecoveryLedger.of(support);
    final notes = await readJournal(
      Directory(p.join(support.path, journal)),
      decode: decodeMoveNote,
    );
    for (final (file, move) in notes) {
      try {
        await _validate(move);
        await _finish(file, move);
        ledger.settled(journal, move.id);
      } on RecoveryRequired catch (error) {
        await quarantine(support, file, error);
        ledger.settled(journal, move.id);
      } on Object catch (error) {
        log.w('finish the move noted at ${file.path}', error);
        ledger.deferred(
          journal,
          move.id,
          paths: const {},
          detail: '$error',
          now: DateTime.now(),
        );
      }
    }
  }

  /// What one note is worth, which the disk decides ([observeMove]) rather
  /// than the note alone: a machine that stopped before the rename left the
  /// chapter at the old path, and rewriting the rows to the new one would
  /// point a year of reviews at a file that never existed.
  Future<void> _finish(File note, UnfinishedMove move) async {
    switch (await observeMove(move)) {
      case MoveLanded():
        await _flushMove(move);
        final result = await TrainingRecords(
          documents,
        ).repoint(DocumentRef(move.from), DocumentRef(move.to));
        switch (result) {
          case Repointed() || NothingToRepoint():
            break;
          case IoFailure(:final detail):
            // Passing: the note stays and the next start tries again.
            throw FileSystemException(detail, move.to);
          case Malformed(:final file, :final line):
            throw RecoveryRequired(
              'Training rows for ${move.from} could not be recovered: '
              '$file at line $line',
            );
        }
      case MoveNeverHappened():
        await _flushMove(move);
      case MoveNotObserved(:final detail):
        // Passing: the note stays and the next start looks again.
        throw FileSystemException(detail, move.to);
      case MoveUnclear(:final detail):
        throw RecoveryRequired(detail);
    }
    await forgetRecord(note, synchronize: _synchronize);
  }

  /// A visible rename is not yet a confirmed namespace change: both parent
  /// entries, and every folder above them up to Documents, are flushed
  /// before the rows follow or the note goes. A cancelled move can name
  /// destination folders never created; only the ones there are flushed.
  Future<void> _flushMove(UnfinishedMove move) async {
    // Windows has no folder flush (flushRecoveryDirectory skips it there).
    if (Platform.isWindows) return;
    final root = p.normalize(p.absolute(documents.path));
    // Configured root aliases are supported: flush the folder they name.
    final resolved = await Directory(root).resolveSymbolicLinks();
    for (final path in [move.from, move.to]) {
      var leaf = p.normalize(
        p.join(resolved, p.relative(p.dirname(path), from: root)),
      );
      while (leaf != resolved &&
          await _type(leaf) == FileSystemEntityType.notFound) {
        leaf = p.dirname(leaf);
      }
      await flushRecoveryAncestry(
        leaf,
        through: resolved,
        synchronize: _synchronize,
      );
    }
  }

  /// A note names two different paths inside Documents, reached without a
  /// link, and the identity of what it moved; anything else is set aside
  /// rather than let rewrite rows.
  Future<void> _validate(UnfinishedMove move) async {
    if (move.identity.trim().isEmpty || move.from == move.to) {
      throw RecoveryRequired(
        'Invalid relocation identity or paths in ${move.id}.',
      );
    }
    final root = p.normalize(p.absolute(documents.path));
    for (final path in [move.from, move.to]) {
      if (!p.isAbsolute(path) ||
          p.normalize(path) != path ||
          !p.isWithin(root, path)) {
        throw RecoveryRequired(
          'Relocation path is outside managed Documents: $path.',
        );
      }
      var at = root;
      for (final part in p.split(p.relative(path, from: root))) {
        at = p.join(at, part);
        if (await _type(at) == FileSystemEntityType.link) {
          throw RecoveryRequired(
            'Relocation path follows a symbolic link: $at.',
          );
        }
      }
    }
  }
}

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

  /// The note's own name.
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

/// A note as written, or a [RecoveryRequired] saying why it is not one.
UnfinishedMove decodeMoveNote(Object? json, String id) {
  if (json is! Map<String, Object?> ||
      json.length != 4 ||
      !json.keys.every(const {'from', 'to', 'identity', 'folder'}.contains)) {
    throw RecoveryRequired('Unsupported relocation schema in $id.');
  }
  final from = json['from'];
  final to = json['to'];
  final identity = json['identity'];
  final folder = json['folder'];
  if (from is! String ||
      to is! String ||
      identity is! String ||
      folder is! bool) {
    throw RecoveryRequired('Malformed relocation note $id.');
  }
  return UnfinishedMove(
    id: id,
    from: from,
    to: to,
    identity: identity,
    folder: folder,
  );
}

Future<FileSystemEntityType> _type(String path) =>
    FileSystemEntity.type(path, followLinks: false);

/// What the disk says happened to [move], which decides what its training
/// rows should name.
///
/// Only the original native identity proves which endpoint holds the move.
/// A later publication or unrelated replacement cannot stand in for it.
Future<MoveVerdict> observeMove(UnfinishedMove move) async {
  try {
    final from = await _identityOf(move.from, move.folder);
    final to = await _identityOf(move.to, move.folder);
    for (final (path, status) in [
      (move.from, from.status),
      (move.to, to.status),
    ]) {
      if (status == _unreadable || status == _changing) {
        return MoveNotObserved(
          '$path could not be looked at (status $status).',
        );
      }
    }
    if (to.status == _present &&
        to.identity == move.identity &&
        from.status == _missing) {
      return const MoveLanded();
    }
    if (from.status == _present &&
        from.identity == move.identity &&
        to.status == _missing) {
      return const MoveNeverHappened();
    }
    return MoveUnclear(
      'The original move from ${move.from} to ${move.to} cannot be identified.',
    );
  } on Object catch (error) {
    return MoveNotObserved('${move.to} could not be looked at: $error');
  }
}

sealed class MoveVerdict {
  const MoveVerdict();
}

/// The old path is empty and the new one holds the original thing moved.
final class MoveLanded extends MoveVerdict {
  const MoveLanded();
}

/// The original thing is still at the old path and the new path is empty.
final class MoveNeverHappened extends MoveVerdict {
  const MoveNeverHappened();
}

/// Neither path holds it, so nobody can say which name the rows should
/// carry. The note is set aside and the rows left as they are: a schedule is
/// not rewritten on a guess.
final class MoveUnclear extends MoveVerdict {
  const MoveUnclear(this.detail);

  /// Why the note was set aside.
  final String detail;
}

/// A path could not be looked at just now (another app holds it, or it
/// changed while being read). The note stays for the next start.
final class MoveNotObserved extends MoveVerdict {
  const MoveNotObserved(this.detail);

  /// What could not be looked at.
  final String detail;
}

Future<({int status, String? identity})> _identityOf(
  String path,
  bool folder,
) async {
  if (folder) {
    final observed = await observeDirectory(path);
    return (status: observed.status, identity: observed.identity);
  }
  final observed = await observeFile(path);
  return (status: observed.status, identity: observed.identity);
}

/// The statuses a native observation reports for a path holding what was
/// asked for, and for a path with nothing at it.
const _present = 0;
const _missing = 1;

/// The statuses for a path that could not be opened or read, and for one that
/// changed while it was read. Neither says what is there.
const _unreadable = 2;
const _changing = 3;

/// Shared chapter quarantine spelling used by both supported app versions.
const recoveryFolder = '.cap-pgn-history';
