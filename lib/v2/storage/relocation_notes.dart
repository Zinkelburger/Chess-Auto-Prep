/// The one thing a relocation cannot do in a single step.
///
/// Moving a chapter is a rename on disk; the training rows that name it are a
/// rewrite of four other files. A machine that stops between them would leave
/// the rows pointing at a name nothing answers to, and the user's schedule,
/// streaks and answers for that chapter would look like another chapter's.
///
/// So a note is written down before the rename and taken away after the rows
/// are rewritten, and the next guarded access finishes the notes it finds
/// before reading or changing this domain. One file per move, because moves can be
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

import 'directory_entries.dart';
import '../diagnostics/log.dart';
import 'journal_records.dart';
import 'recovery_quarantine.dart';
import 'atomic_write.dart';
import 'document_ref.dart';
import 'training_records.dart';

/// The training rows' half of a relocation, which is a move's second write.
///
/// One owner for the pair, so the note and the rewrite cannot drift apart:
/// the caller mints a name for the move, records the note before the rename,
/// and asks for the rewrite afterwards; the note goes away only once the rows
/// owe nothing. [finishOwed] is what the access guard calls to make good
/// on the notes an earlier one left.
final class RelocationNotes {
  const RelocationNotes({
    required PendingRepoints notes,
    required TrainingRecords records,
    Future<void> Function(String) synchronize = syncDirectory,
  }) : _notes = notes,
       _records = records,
       _synchronize = synchronize;

  final PendingRepoints _notes;
  final TrainingRecords _records;
  final Future<void> Function(String) _synchronize;

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
    await _syncMove(from.path, to.path);
    final result = await _records.repoint(from, to);
    if (_settled(result)) await _notes.discard(note);
    return result;
  }

  /// Validate every retained note without changing its namespace or rows.
  Future<bool> inspect() async => (await _notes.read()).isNotEmpty;

  /// Finishes the rows every move that stopped half way still owes. A note
  /// that cannot be finished is set aside and logged; the others still run.
  Future<void> finishOwed() async {
    final notes = await readJournal(_notes._folder, decode: decodeMoveNote);
    for (final (file, move) in notes) {
      try {
        await _notes._validate(move);
        await _finish(move);
      } on RecoveryRequired catch (error) {
        await quarantine(_notes.support, file, error);
      } on Object catch (error) {
        log.w('finish the move noted at ${file.path}', error);
      }
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
        if (result is IoFailure) {
          // Passing: the note stays and the next start tries again.
          throw FileSystemException(result.detail, move.to);
        }
        if (!_settled(result)) {
          throw RecoveryRequired(
            'Training rows for ${move.from} could not be recovered: '
            '${_repointProblem(result)}',
          );
        }
      case MoveNeverHappened():
        await _syncMove(move.from, move.to);
        await _notes.discard(move.id);
      case MoveUnclear(:final detail):
        throw RecoveryRequired(detail);
    }
  }

  /// A visible rename is not yet a confirmed namespace change. Keep its note
  /// until both parent entries and any new destination ancestry are flushed.
  /// Recovery uses the same barrier before changing training references.
  Future<void> _syncMove(String from, String to) => _syncAncestors(
    [p.dirname(from), p.dirname(to)],
    root: p.normalize(p.absolute(_notes.documents.path)),
    synchronize: _synchronize,
  );
}

/// Whether the training rows still owe this move anything.
bool _settled(RepointResult result) =>
    result is Repointed || result is NothingToRepoint;

String _repointProblem(RepointResult result) => switch (result) {
  Malformed(:final file, :final line) => '$file at line $line',
  IoFailure(:final detail) => detail,
  _ => 'repoint was not confirmed',
};

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
  PendingRepoints(
    Directory support, {
    required this.documents,
    Future<void> Function(String) synchronize = syncDirectory,
  }) : _configuredSupport = support,
       _synchronize = synchronize,
       support = _supportRoot(support) {
    // Capture before backups or another preparation creates nested Support
    // folders. A retry through this owner must flush the same ancestry.
    _metadataBoundary = _existingParent(this.support).path;
  }

  final Directory _configuredSupport;
  late final String _metadataBoundary;
  final Future<void> Function(String) _synchronize;

  /// The Support folder itself; the notes are one folder inside it.
  final Directory support;
  final Directory documents;

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
  }) => _checked('Record relocation $id', () async {
    final move = UnfinishedMove(
      id: id,
      from: from,
      to: to,
      identity: identity,
      folder: folder,
    );
    await _validate(move);
    await _checkFolder(create: true);
    final path = _pathOf(id);
    if (await _type(path) != FileSystemEntityType.notFound ||
        await _type(temporaryPathFor(path)) != FileSystemEntityType.notFound) {
      throw RecoveryRequired('Relocation metadata already exists for $id.');
    }
    // Persist new Support ancestry and its containing entry, including on
    // retry after failed preparation. Ancestors above the pre-existing parent
    // were not changed and may be outside the macOS sandbox's permissions.
    await _syncAncestors(
      [_folder.path],
      root: _metadataBoundary,
      synchronize: _synchronize,
    );
    await createFileExclusively(path, utf8.encode(jsonEncode(move.toJson())));
  });

  /// Takes away the one note [id] names, the rows it describes now naming
  /// what they should. A note that is not there is nothing to take away.
  Future<void> discard(String id) =>
      _checked('Remove relocation $id', () async {
        _validateId(id);
        if (!await _checkFolder()) return;
        final path = _pathOf(id);
        final observed = await observeFile(path);
        if (observed.status == _missing) return;
        if (observed.status != _present) {
          throw RecoveryRequired(
            'Relocation note $path cannot be read as a regular file.',
          );
        }
        await _readOne(id);
        await File(path).delete();
        if (!Platform.isWindows) await syncDirectory(_folder.path);
      });

  /// Every owed move, oldest first. Unknown metadata is preserved and stops
  /// recovery; ignoring it would let later work obscure an unfinished move.
  Future<List<UnfinishedMove>> read() => _checked(
    'Read relocation notes',
    () async {
      if (!await _checkFolder()) return const [];
      final names = <String>[];
      await for (final entry in directoryEntries(_folder, followLinks: false)) {
        if (entry is! File || p.extension(entry.path) != '.json') {
          throw RecoveryRequired(
            'Unsupported relocation metadata at ${entry.path}.',
          );
        }
        final id = p.basenameWithoutExtension(entry.path);
        _validateId(id);
        names.add(id);
      }
      names.sort();
      final moves = <UnfinishedMove>[];
      for (final name in names) {
        moves.add(await _readOne(name));
      }
      return moves;
    },
  );

  Future<UnfinishedMove> _readOne(String id) async {
    final observed = await observeFile(_pathOf(id));
    if (observed.status != _present) {
      throw RecoveryRequired(
        'Relocation note $id cannot be read as a regular file.',
      );
    }
    final move = decodeMoveNote(jsonDecode(utf8.decode(observed.bytes!)), id);
    await _validate(move);
    return move;
  }

  Future<void> _validate(UnfinishedMove move) async {
    _validateId(move.id);
    if (move.identity.trim().isEmpty || move.from == move.to) {
      throw RecoveryRequired(
        'Invalid relocation identity or paths in ${move.id}.',
      );
    }
    await _validatePath(move.from);
    await _validatePath(move.to);
  }

  Future<void> _validatePath(String path) async {
    final root = p.normalize(p.absolute(documents.path));
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
        throw RecoveryRequired('Relocation path follows a symbolic link: $at.');
      }
    }
  }

  Future<bool> _checkFolder({bool create = false}) async {
    if (_supportRoot(_configuredSupport).path != support.path) {
      throw const RecoveryRequired('The configured Support directory changed.');
    }
    for (final directory in [support, _folder]) {
      var observed = await observeDirectory(directory.path);
      if (observed.status == _missing) {
        if (!create) return false;
        await directory.create(recursive: true);
        observed = await observeDirectory(directory.path);
      }
      if (observed.status != _present) {
        throw RecoveryRequired(
          'Relocation metadata directory is unreadable or unsupported: ${directory.path}.',
        );
      }
    }
    return true;
  }

  String _pathOf(String id) => p.join(_folder.path, '$id.json');
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

// Resolve configured aliases once, before any asynchronous operation. The
// pinned directory and its metadata descendants still receive no-follow probes.
Directory _supportRoot(Directory directory) {
  final absolute = Directory(p.normalize(p.absolute(directory.path)));
  final ancestor = absolute.existsSync() ? absolute : _existingParent(absolute);
  return Directory(
    p.normalize(
      p.join(
        ancestor.resolveSymbolicLinksSync(),
        p.relative(absolute.path, from: ancestor.path),
      ),
    ),
  );
}

Directory _existingParent(Directory directory) {
  var parent = directory.parent;
  while (!parent.existsSync()) {
    final next = parent.parent;
    if (next.path == parent.path) {
      throw FileSystemException(
        'No accessible Support ancestor',
        directory.path,
      );
    }
    parent = next;
  }
  return parent;
}

/// Recovery cannot safely finish, so the caller must not read or mutate this
/// Documents domain until the retained metadata is reconciled.
final class RecoveryRequired implements Exception {
  const RecoveryRequired(this.detail);
  final String detail;

  @override
  String toString() => 'Recovery required: $detail';
}

Future<T> _checked<T>(String action, Future<T> Function() work) async {
  try {
    return await work();
  } on RecoveryRequired {
    rethrow;
  } on Object catch (error) {
    throw RecoveryRequired('$action: $error');
  }
}

void _validateId(String id) {
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').hasMatch(id)) {
    throw RecoveryRequired('Unsupported relocation note id: $id.');
  }
}

Future<FileSystemEntityType> _type(String path) =>
    FileSystemEntity.type(path, followLinks: false);

const _folderName = 'unfinished-moves';

/// Flush children before their containing entries, once per directory. A
/// cancelled move can name absent destination folders; only proven absence
/// permits skipping one. Errors and unsupported entries preserve the note.
Future<void> _syncAncestors(
  List<String> leaves, {
  required String root,
  required Future<void> Function(String) synchronize,
}) async {
  // The native Windows adapter has no directory durability guarantee. Keep
  // that existing platform limitation explicit; POSIX errors must propagate.
  if (Platform.isWindows) return;
  // Configured root aliases are supported. Resolve that boundary, while the
  // descendants below it still receive the strict no-follow observations.
  final resolvedRoot = await Directory(root).resolveSymbolicLinks();
  final paths = <String>{};
  for (final leaf in leaves) {
    if (leaf != root && !p.isWithin(root, leaf)) {
      throw FileSystemException(
        'Relocation directory is outside its root',
        leaf,
      );
    }
    var path = p.normalize(p.join(resolvedRoot, p.relative(leaf, from: root)));
    while (true) {
      paths.add(path);
      if (path == resolvedRoot) break;
      path = p.dirname(path);
    }
  }
  final ordered = paths.toList()
    ..sort((a, b) => p.split(b).length.compareTo(p.split(a).length));
  for (final path in ordered) {
    final observed = await observeDirectory(path);
    if (observed.status == _missing && path != resolvedRoot) continue;
    if (observed.status != _present) {
      throw FileSystemException('Relocation directory cannot be flushed', path);
    }
    await synchronize(path);
  }
}

/// What the disk says happened to [move], which decides what its training
/// rows should name.
///
/// Only the original native identity proves which endpoint holds the move.
/// A later publication or unrelated replacement cannot stand in for it.
Future<MoveVerdict> observeMove(UnfinishedMove move) async {
  try {
    final from = await _identityOf(move.from, move.folder);
    final to = await _identityOf(move.to, move.folder);
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
    return MoveUnclear('${move.to} could not be looked at: $error');
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
/// carry. The note stays; a schedule is not rewritten on a guess.
final class MoveUnclear extends MoveVerdict {
  const MoveUnclear(this.detail);

  /// Why recovery must stop before later reads or mutations.
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

/// Shared chapter quarantine spelling used by both supported app versions.
const recoveryFolder = '.cap-pgn-history';
