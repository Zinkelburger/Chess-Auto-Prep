import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'backups.dart';
import 'book_references.dart';
import 'compound_commit.dart';
import 'document_ref.dart';
import 'line_progress.dart';
import 'operation_id.dart';
import 'operation_journal.dart';
import 'recovery_files.dart';
import 'recovery_ledger.dart';
import 'training_rows.dart';

enum CompoundWriteStep {
  prepared,
  intent,
  document,
  secondaryDocument,
  training,
  books,
  completed,
}

/// One PGN and books, or two PGNs with their training files, under caller locks.
///
/// The edit is written down in `Support/compound-writes/<id>.json` before
/// any participant changes, and the record is removed once all have
/// ([OperationJournal]): the PGNs are its pivots, rewritten from their exact
/// recorded bytes, and the book selectors or training rows follow them. A
/// process killed in between, or a step that failed, leaves the record, and
/// the next access or start finishes it ([recover]): books and training
/// rows that changed in the meantime are renamed or moved again as they now
/// are. Until then the [RecoveryLedger] owes it, and it guards its PGNs
/// alone. An edit whose PGN another writer changed is undone whole, each
/// PGN it rewrote put back where it still holds the edit's bytes, and its
/// record set aside and logged rather than blocking every later open and
/// save; one whose books or training rows can never follow is finished and
/// its record set aside too.
final class CompoundWrites {
  CompoundWrites({
    required Directory documents,
    required Directory support,
    this.testHook,
    this.putBackHook,
    DateTime Function() clock = DateTime.now,
    Future<void> Function(String) synchronize = syncDirectory,
  }) : _configuredDocuments = documents,
       _configuredSupport = support,
       documents = canonicalRecoveryRoot(documents),
       support = canonicalRecoveryRoot(support) {
    _journal = OperationJournal(
      name: journal,
      support: this.support,
      decode: (value, id) {
        final note = _decode(id, value);
        _validate(note.command);
        return note;
      },
      participants: _participants,
      steps: (
        prepared: CompoundWriteStep.prepared,
        intent: CompoundWriteStep.intent,
        completed: CompoundWriteStep.completed,
      ),
      finished: (_) {
        // As many as the ledger keeps receipts for, three PGN keys each.
        while (_published.length > 3 * RecoveryLedger.receiptsKept) {
          _published.remove(_published.keys.first);
        }
      },
      testHook: testHook == null
          ? null
          : (step) => testHook!(step as CompoundWriteStep),
      clock: clock,
      synchronize: synchronize,
    );
  }

  /// The folder under Support the records are written in.
  static const journal = 'compound-writes';

  final Directory _configuredDocuments;
  final Directory _configuredSupport;
  final Directory documents;
  final Directory support;
  final Future<void> Function(CompoundWriteStep)? testHook;

  /// Told after each PGN an edit that is set aside puts back.
  final Future<void> Function()? putBackHook;
  late final OperationJournal<_Note> _journal;

  // The native identity of what this owner published. Another owner's retry
  // gets content-only revisions, so it never vouches for a file it did not
  // observe being installed.
  final _published = <(String, String?), Revision>{};
  Revision? publishedRevision(String id, {String? path}) =>
      _published[(id, path)];

  String get _books => p.join(support.path, 'books.json');

  /// Writes [command] down and carries it out. An exact retry of an edit
  /// this process finished writes nothing and is [Finished]; one still
  /// recorded is finished now. [Refused] when nothing was written: the
  /// command is invalid, its id names another edit, or a participant is not
  /// what it was planned from.
  Future<Settlement> commit(CompoundCommit command) async {
    try {
      _checkRoots();
      final canonical = _canonicalCommand(command, _configuredDocuments);
      _validate(canonical);
      final named = await _journal.named(canonical.id);
      if (named == null) return await _journal.run(_Note(canonical));
      if (!_same(named.record.command, canonical)) {
        return const Refused(IdInUse());
      }
      if (named.done) return const Finished();
      return await _journal.finish(named.record, setAside: false);
    } on Object catch (error) {
      return Refused(NotWritten(_detail(error)));
    }
  }

  void _checkRoots() {
    if (canonicalRecoveryRoot(_configuredDocuments).path != documents.path ||
        canonicalRecoveryRoot(_configuredSupport).path != support.path) {
      throw const RecoveryRequired('The configured profile root changed.');
    }
  }

  CompoundCommit _canonicalCommand(
    CompoundCommit command,
    Directory configured,
  ) {
    String canonical(String path) {
      if (path.contains('\u0000') ||
          !p.isAbsolute(path) ||
          p.normalize(path) != path) {
        throw RecoveryRequired(
          'Compound document is not a managed PGN: $path.',
        );
      }
      final originalRoot = p.normalize(p.absolute(configured.path));
      return p.isWithin(originalRoot, path)
          ? p.join(documents.path, p.relative(path, from: originalRoot))
          : path;
    }

    if (command.secondary case final secondary?) {
      return CompoundCommit.pair(
        id: command.id,
        training: command.training,
        primary: CompoundDocument(
          path: canonical(command.documentPath),
          before: command.documentBefore,
          after: command.documentAfter,
        ),
        secondary: CompoundDocument(
          path: canonical(secondary.path),
          before: secondary.before,
          after: secondary.after,
        ),
      );
    }
    return CompoundCommit(
      id: command.id,
      documentPath: canonical(command.documentPath),
      documentBefore: command.documentBefore,
      documentAfter: command.documentAfter,
      booksBefore: command.booksBefore,
      booksAfter: command.booksAfter,
    );
  }

  /// Finishes the edits a stopped process began, and tells the ledger what
  /// each came to. One that can never be finished — a PGN changed since, or
  /// the record is damaged — is set aside and logged; the rest still run.
  Future<void> recover() async {
    _checkRoots();
    await _journal.recover();
  }

  /// Stops the owed edit [id] guarding its PGNs, once it has guarded them
  /// too long ([OperationJournal.stopGuarding]).
  Future<void> stopGuarding(String id) async {
    _checkRoots();
    await _journal.stopGuarding(id);
  }

  /// The edit this process finished under [id], or null.
  Future<CompoundCommit?> completed(String id) async {
    OperationId(id);
    return _journal.ledger.receipt<_Note>(journal, id)?.command;
  }

  /// The PGNs an edit rewrites, then what refers to them: the book
  /// selectors of a section rename, or the training rows of a line move.
  Participants _participants(_Note note, {bool following = false}) {
    final command = note.command;
    Future<void> step(CompoundWriteStep step) async => testHook?.call(step);
    final pivots = <_ExactText>[];
    for (final (i, document) in command.documents.indexed) {
      pivots.add(
        _ExactText(
          document,
          documents: documents,
          recorded: note.recorded,
          previous: pivots.lastOrNull,
          installed: (file) {
            final revision = Revision(
              file.sha256Hex!,
              nativeIdentity: file.identity,
            );
            _published[(command.id, document.path)] = revision;
            if (i == 0) _published[(command.id, null)] = revision;
          },
          keep: _keep,
          landed: () => step(
            i == 0
                ? CompoundWriteStep.document
                : CompoundWriteStep.secondaryDocument,
          ),
          putBackHook: putBackHook,
        ),
      );
    }
    return (
      pivots: pivots,
      references: [
        if (command.secondary == null)
          RenamedSections(
            _books,
            before: command.booksBefore,
            after: command.booksAfter,
            repertoireRoot: p.join(documents.path, 'repertoires'),
            written: () async {
              await step(CompoundWriteStep.books);
              await step(CompoundWriteStep.training);
            },
          )
        else
          LineRows(
            documents,
            command.training,
            written: () => step(CompoundWriteStep.training),
          ),
      ],
    );
  }

  /// Keeps [text], the bytes an edit wrote at the PGN [path], among its
  /// kept versions before they are put back: the edit is the user's work.
  Future<void> _keep(String path, String text) async {
    final relative = p.relative(path, from: documents.path);
    final bytes = utf8.encode(text);
    final kept = await BackupArchive(Directory(p.join(support.path, 'backups')))
        .record(
          id: backupId(relative),
          // The spelling the store keeps its versions under.
          documentPath: p.join(
            p.normalize(p.absolute(_configuredDocuments.path)),
            relative,
          ),
          bytes: bytes,
          hash: '${sha256.convert(bytes)}',
        );
    if (kept case BackupFailed(:final detail)) {
      throw FileSystemException('The edit could not be kept: $detail', path);
    }
  }

  String _detail(Object error) => switch (error) {
    RecoveryRequired(:final detail) => detail,
    FileSystemException() => 'Compound persistence failed: $error',
    FormatException() => 'Compound metadata or snapshot is malformed.',
    NativeNameCollision() => 'Compound metadata appeared during preparation.',
    _ => '$error',
  };

  void _validate(CompoundCommit command) {
    OperationId(command.id);
    final root = p.normalize(p.absolute(documents.path));
    if (command.secondary case final secondary?
        when p.equals(secondary.path, command.documentPath)) {
      throw const RecoveryRequired(
        'Compound PGN participants must be distinct.',
      );
    }
    for (final document in command.documents) {
      final path = document.path;
      if (path.contains('\u0000') ||
          !p.isAbsolute(path) ||
          p.normalize(path) != path ||
          !p.isWithin(root, path) ||
          p.extension(path).toLowerCase() != '.pgn') {
        throw RecoveryRequired(
          'Compound document is not a managed PGN: $path.',
        );
      }
      _utf8(document.before);
      _utf8(document.after);
    }
    if (command.training.isNotEmpty &&
        (command.secondary == null ||
            command.training.length != trainingParticipants.length ||
            command.training.map((f) => f.name).toSet().length !=
                trainingParticipants.length ||
            command.training.any(
              (f) => !trainingParticipants.contains(f.name),
            ))) {
      throw const RecoveryRequired(
        'Invalid training participants in compound edit.',
      );
    }
    for (final file in command.training) {
      if (file.before != null) _utf8(file.before!);
      if (file.after != null) _utf8(file.after!);
    }
    for (final books in [command.booksBefore, command.booksAfter]) {
      if (books == null) continue;
      _utf8(books);
      if (jsonDecode(books) is! Map<String, Object?>) {
        throw const RecoveryRequired('A book snapshot is not a JSON object.');
      }
    }
  }
}

final class _Note implements Recorded {
  _Note(this.command, {this.live = true, this.recorded = false});
  final CompoundCommit command;

  /// Read back from its record rather than just planned: a PGN the edit
  /// leaves as it is has then landed.
  final bool recorded;

  @override
  String get id => command.id;

  /// Earlier builds kept finished and abandoned records too; only a record
  /// that reached `committing` still has anything to publish.
  @override
  final bool live;

  @override
  Map<String, Object?> get json => command.secondary != null
      ? {
          'version': command.training.isEmpty ? 2 : 3,
          if (command.training.isNotEmpty)
            'training': [for (final file in command.training) file.toJson()],
          'id': command.id,
          'state': 'committing',
          'documents': [
            for (final document in command.documents)
              {
                'path': document.path,
                'before': document.before,
                'after': document.after,
              },
          ],
        }
      : {
          'version': 1,
          'id': command.id,
          'state': 'committing',
          'documentPath': command.documentPath,
          'documentBefore': command.documentBefore,
          'documentAfter': command.documentAfter,
          'booksBefore': command.booksBefore,
          'booksAfter': command.booksAfter,
        };
}

_Note _decode(String id, Object? json) {
  if (json is Map<String, Object?> &&
      json['version'] is int &&
      (json['version'] == 2 || json['version'] == 3)) {
    return _decodePair(id, json);
  }
  const fields = {
    'version',
    'id',
    'state',
    'documentPath',
    'documentBefore',
    'documentAfter',
    'booksBefore',
    'booksAfter',
  };
  if (json is! Map<String, Object?> ||
      json.length != fields.length ||
      !json.keys.every(fields.contains) ||
      json['version'] is! int ||
      json['version'] != 1 ||
      json['id'] != id ||
      json['documentPath'] is! String ||
      json['documentBefore'] is! String ||
      json['documentAfter'] is! String ||
      (json['booksBefore'] != null && json['booksBefore'] is! String) ||
      (json['booksAfter'] != null && json['booksAfter'] is! String)) {
    throw RecoveryRequired('Unsupported compound schema in $id.');
  }
  final state = json['state'];
  if (!_states.contains(state)) {
    throw RecoveryRequired('Unsupported compound state in $id.');
  }
  return _Note(
    CompoundCommit(
      id: id,
      documentPath: json['documentPath'] as String,
      documentBefore: json['documentBefore'] as String,
      documentAfter: json['documentAfter'] as String,
      booksBefore: json['booksBefore'] as String?,
      booksAfter: json['booksAfter'] as String?,
    ),
    live: state == 'committing',
    recorded: true,
  );
}

_Note _decodePair(String id, Map<String, Object?> json) {
  final fields = {
    'version',
    'id',
    'state',
    'documents',
    if (json['version'] == 3) 'training',
  };
  final entries = json['documents'];
  if (json.length != fields.length ||
      !json.keys.every(fields.contains) ||
      json['id'] != id ||
      entries is! List<Object?> ||
      entries.length != 2) {
    throw RecoveryRequired('Unsupported compound pair schema in $id.');
  }
  CompoundDocument document(Object? entry) {
    if (entry is! Map<String, Object?> ||
        entry.length != 3 ||
        entry['path'] is! String ||
        entry['before'] is! String ||
        entry['after'] is! String) {
      throw RecoveryRequired('Unsupported compound participant in $id.');
    }
    return CompoundDocument(
      path: entry['path'] as String,
      before: entry['before'] as String,
      after: entry['after'] as String,
    );
  }

  final state = json['state'];
  if (!_states.contains(state)) {
    throw RecoveryRequired('Unsupported compound state in $id.');
  }
  return _Note(
    CompoundCommit.pair(
      id: id,
      training: json['version'] == 3 ? _training(json['training']) : const [],
      primary: document(entries[0]),
      secondary: document(entries[1]),
    ),
    live: state == 'committing',
    recorded: true,
  );
}

const _states = {'prepared', 'committing', 'complete', 'cancelled'};

bool _same(CompoundCommit a, CompoundCommit b) =>
    a.id == b.id &&
    a.documentPath == b.documentPath &&
    a.documentBefore == b.documentBefore &&
    a.documentAfter == b.documentAfter &&
    a.booksBefore == b.booksBefore &&
    a.booksAfter == b.booksAfter &&
    a.secondary?.path == b.secondary?.path &&
    a.secondary?.before == b.secondary?.before &&
    a.secondary?.after == b.secondary?.after &&
    jsonEncode(a.training.map((f) => f.toJson()).toList()) ==
        jsonEncode(b.training.map((f) => f.toJson()).toList());

void _utf8(String text) {
  if (text.contains('\u0000') ||
      utf8.decode(utf8.encode('x$text')) != 'x$text') {
    throw const RecoveryRequired('A compound snapshot is not safe UTF-8 text.');
  }
}

List<CompoundTraining> _training(Object? value) {
  if (value is! List<Object?> || value.length != trainingParticipants.length) {
    throw const RecoveryRequired('Invalid training snapshots.');
  }
  return [for (final row in value) _trainingFile(row)];
}

CompoundTraining _trainingFile(Object? row) {
  if (row is! Map<String, Object?> ||
      row.length != 3 ||
      !row.keys.every({'name', 'before', 'after'}.contains) ||
      row['name'] is! String ||
      !trainingParticipants.contains(row['name']) ||
      (row['before'] != null && row['before'] is! String) ||
      (row['after'] != null && row['after'] is! String)) {
    throw const RecoveryRequired('Invalid training snapshot.');
  }
  return CompoundTraining(
    name: row['name'] as String,
    before: row['before'] as String?,
    after: row['after'] as String?,
  );
}

/// A PGN an edit rewrites whole, from its exact recorded bytes to its
/// others, in a folder under Documents that must be a real folder.
final class _ExactText implements Pivot {
  _ExactText(
    this.document, {
    required this.documents,
    this.recorded = false,
    this.previous,
    this.keep,
    this.installed,
    this.landed,
    this.putBackHook,
  });

  final CompoundDocument document;

  /// The canonical Documents folder.
  final Directory documents;

  /// Whether the edit is written down. A PGN it leaves as it is holds its
  /// before until then, as admission needs, and has landed from then on,
  /// so it never keeps a landed edit from following or being let pass.
  final bool recorded;

  /// The PGN the edit rewrites before this one, which has landed before
  /// this one is written: a pair's source is durable before its target
  /// changes.
  final _ExactText? previous;

  /// Keeps what it holds before it is put back.
  final Future<void> Function(String path, String text)? keep;

  /// Told the native file this attempt installed.
  final void Function(NativeFileObservation file)? installed;

  /// Told once it holds its after bytes durably.
  final Future<void> Function()? landed;

  /// Told once its before bytes are back.
  final Future<void> Function()? putBackHook;
  var _settled = false;

  String get _path => document.path;
  bool get _unchanged => document.after == document.before;

  @override
  Set<String> get paths => {_path};

  @override
  Future<Holds> look() async {
    try {
      await _parents();
      final text = await recoveryText(_path);
      if (text == document.before && !(recorded && _unchanged)) {
        return const HoldsBefore();
      }
      if (text == document.after) return const HoldsAfter();
      return HoldsOther('Compound participant changed externally: $_path.');
    } on RecoveryRequired catch (error) {
      return HoldsOther(error.detail);
    } on FormatException {
      return HoldsOther('Compound participant is not UTF-8 text: $_path.');
    } on FileSystemException catch (error) {
      return CannotTell('$error');
    }
  }

  /// Throws unless Documents and each folder above the PGN in it is a
  /// real folder.
  Future<void> _parents() async {
    if (!await recoveryDirectory(documents)) {
      throw const RecoveryRequired('The Documents directory is missing.');
    }
    var parent = documents.path;
    for (final part in p.split(p.relative(p.dirname(_path), from: parent))) {
      if (part == '.') continue;
      parent = p.join(parent, part);
      if (!await recoveryDirectory(Directory(parent))) {
        throw RecoveryRequired('The document directory is missing: $parent.');
      }
    }
  }

  @override
  Future<void> apply() async {
    await previous?.settle();
    if (_unchanged) return;
    await discardLeftoverStage(_path);
    await replaceFile(_path, utf8.encode(document.after), installed: installed);
  }

  /// Once per attempt, whichever attempt wrote it.
  @override
  Future<void> settle() async {
    if (_settled) return;
    _settled = true;
    // A write an earlier attempt landed may have lost its folder flush.
    await flushRecoveryDirectory(p.dirname(_path));
    await landed?.call();
  }

  @override
  Future<bool> putBack() async {
    if (_unchanged || await look() is! HoldsAfter) return false;
    await keep?.call(_path, document.after);
    await discardLeftoverStage(_path);
    await replaceFile(_path, utf8.encode(document.before));
    await putBackHook?.call();
    return true;
  }
}
