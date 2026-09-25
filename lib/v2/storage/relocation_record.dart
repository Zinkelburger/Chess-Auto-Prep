import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup_relocation.dart';
import 'backups.dart';
import 'book_references.dart';
import 'document_ref.dart';
import 'directory_snapshot.dart';
import 'relocation_notes.dart' show RecoveryRequired;
import 'training_records.dart';
import 'training_rows.dart';

enum FileRelocationKind { move, delete }

enum RelocationState { prepared, committing, complete, cancelled }

/// One concrete namespace move and its complete captured reference read set.
/// Versions remain operation-specific; old file records keep their encoding.
sealed class RelocationRecord {
  RelocationRecord();

  factory RelocationRecord.fromJson(
    Object? value, {
    required String id,
    required Directory documents,
  }) => switch (value) {
    {'version': 1} => FileRelocationRecord.fromJson(
      value,
      id: id,
      documents: documents,
    ),
    {'version': 2} => FolderRelocationRecord.fromJson(
      value,
      id: id,
      documents: documents,
    ),
    _ => throw const RecoveryRequired('Unsupported relocation version.'),
  };

  String get id;
  String get from;
  String get to;
  String get trainingRoot;
  String get identity;
  TrainingRepointPlan get training;
  String? get booksBefore;
  String? get booksAfter;
  RelocationState get state;
  set state(RelocationState value);
  Iterable<BackupMove> get backups;
  Map<String, Object?> toJson(RelocationState phase);
  void validate({required Directory documents, required Directory support});
}

/// The durable immutable plan of a single file relocation. Only its phase
/// changes; decoding verifies every derived snapshot against captured inputs.
final class FileRelocationRecord extends RelocationRecord {
  FileRelocationRecord({
    required this.id,
    required this.kind,
    required this.from,
    required this.to,
    required this.trainingRoot,
    required this.identity,
    required this.hash,
    required this.training,
    required this.booksBefore,
    required this.booksAfter,
    required this.backup,
    this.state = RelocationState.prepared,
  });

  factory FileRelocationRecord.fromJson(
    Object? value, {
    required String id,
    required Directory documents,
  }) {
    _keys(value, const {
      'version',
      'kind',
      'id',
      'state',
      'from',
      'to',
      'identity',
      'hash',
      'trainingRoot',
      'training',
      'rowsChanged',
      'booksBefore',
      'booksAfter',
      'backup',
    });
    final json = value as Map<String, Object?>;
    if (json['version'] is! int || json['version'] != 1 || json['id'] != id) {
      throw const RecoveryRequired('Unsupported relocation version or id.');
    }
    final kind = FileRelocationKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (kind == null) {
      throw const RecoveryRequired('Unsupported relocation kind.');
    }
    final from = _string(json['from']);
    final to = _string(json['to']);
    final trainingRoot = _string(json['trainingRoot']);
    final training = _decodeTraining(json, documents);
    final state = RelocationState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    if (state == null || json['backup'] is! Map<String, Object?>) {
      throw const RecoveryRequired('Unsupported relocation state or backup.');
    }
    return FileRelocationRecord(
      id: id,
      kind: kind,
      from: from,
      to: to,
      trainingRoot: trainingRoot,
      identity: _string(json['identity']),
      hash: _string(json['hash']),
      training: training,
      booksBefore: _nullable(json['booksBefore']),
      booksAfter: _nullable(json['booksAfter']),
      backup: BackupMove.fromJson(json['backup'] as Map<String, Object?>),
      state: state,
    );
  }

  @override
  final String id;
  final FileRelocationKind kind;
  @override
  final String from;
  @override
  final String to;
  @override
  final String trainingRoot;
  @override
  final String identity;
  final String hash;
  @override
  final TrainingRepointPlan training;
  @override
  final String? booksBefore;
  @override
  final String? booksAfter;
  final BackupMove backup;
  @override
  Iterable<BackupMove> get backups => [backup];
  @override
  RelocationState state;

  @override
  Map<String, Object?> toJson(RelocationState phase) => {
    'version': 1,
    'kind': kind.name,
    'id': id,
    'state': phase.name,
    'from': from,
    'to': to,
    'trainingRoot': trainingRoot,
    'identity': identity,
    'hash': hash,
    'training': [
      for (final f in training.files)
        {'name': f.name, 'before': f.before, 'after': f.after},
    ],
    'rowsChanged': training.rowsChanged,
    'booksBefore': booksBefore,
    'booksAfter': booksAfter,
    'backup': backup.toJson(),
  };

  @override
  void validate({required Directory documents, required Directory support}) {
    validateRelocationId(id);
    validateRelocationPaths(documents, from, to);
    if (kind == FileRelocationKind.delete) validateDeletionId(id);
    if (kind == FileRelocationKind.delete &&
        to !=
            p.join(
              p.dirname(from),
              '.cap-pgn-history',
              '$id-${p.basename(from)}',
            )) {
      throw const RecoveryRequired('The delete recovery target is invalid.');
    }
    if (!p.isAbsolute(trainingRoot) ||
        p.normalize(trainingRoot) != trainingRoot ||
        trainingRoot.contains('\u0000')) {
      throw const RecoveryRequired('Unsupported training root spelling.');
    }
    if (identity.isEmpty ||
        identity.contains('\u0000') ||
        RegExp(r'^[0-9a-f]{64}$').stringMatch(hash) != hash) {
      throw const RecoveryRequired('Unsupported relocation identity or hash.');
    }
    if (backup.operationId != id ||
        backup.documentPath != to ||
        backup.rootPath != p.join(support.path, 'backups') ||
        backup.fromId != backupId(p.relative(from, from: documents.path)) ||
        backup.toId != backupId(p.relative(to, from: documents.path))) {
      throw const RecoveryRequired('Relocation backup ownership disagrees.');
    }
    if (relocateBookReferences(
          booksBefore,
          repertoireRoot: p.join(documents.path, 'repertoires'),
          from: from,
          to: to,
          directory: false,
        ) !=
        booksAfter) {
      throw const RecoveryRequired('Relocation book snapshots disagree.');
    }
    for (final text in [
      booksBefore,
      booksAfter,
      for (final f in training.files) ...[f.before, f.after],
    ]) {
      if (text != null && !_safeText(text)) {
        throw const RecoveryRequired('Relocation snapshot is not exact UTF-8.');
      }
    }
  }
}

/// A whole native directory, including sidecars and recovery contents, moves
/// once. Backup ownership is captured for every PGN in that exact inventory.
final class FolderRelocationRecord extends RelocationRecord {
  FolderRelocationRecord({
    required this.id,
    required this.from,
    required this.to,
    required this.trainingRoot,
    required this.snapshot,
    required this.training,
    required this.booksBefore,
    required this.booksAfter,
    required Map<String, BackupMove> backupByPath,
    this.state = RelocationState.prepared,
  }) : backupByPath = Map.unmodifiable(backupByPath);

  factory FolderRelocationRecord.fromJson(
    Object? value, {
    required String id,
    required Directory documents,
  }) {
    _keys(value, const {
      'version',
      'kind',
      'id',
      'state',
      'from',
      'to',
      'identity',
      'trainingRoot',
      'entries',
      'training',
      'rowsChanged',
      'booksBefore',
      'booksAfter',
      'backups',
    });
    final json = value as Map<String, Object?>;
    if (json['version'] is! int ||
        json['version'] != 2 ||
        json['kind'] != 'folder' ||
        json['id'] != id) {
      throw const RecoveryRequired('Unsupported folder relocation schema.');
    }
    final state = RelocationState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    if (state == null) {
      throw const RecoveryRequired('Unsupported folder relocation state.');
    }
    return FolderRelocationRecord(
      id: id,
      from: _string(json['from']),
      to: _string(json['to']),
      trainingRoot: _string(json['trainingRoot']),
      snapshot: DirectorySnapshot.fromJson(
        json['entries'],
        identity: _string(json['identity']),
      ),
      training: _decodeTraining(json, documents),
      booksBefore: _nullable(json['booksBefore']),
      booksAfter: _nullable(json['booksAfter']),
      backupByPath: _decodeFolderBackups(json['backups']),
      state: state,
    );
  }

  @override
  final String id;
  @override
  final String from;
  @override
  final String to;
  @override
  final String trainingRoot;
  final DirectorySnapshot snapshot;
  @override
  final TrainingRepointPlan training;
  @override
  final String? booksBefore;
  @override
  final String? booksAfter;
  final Map<String, BackupMove> backupByPath;
  @override
  RelocationState state;
  @override
  String get identity => snapshot.identity;
  @override
  Iterable<BackupMove> get backups => backupByPath.values;

  @override
  Map<String, Object?> toJson(RelocationState phase) => {
    'version': 2,
    'kind': 'folder',
    'id': id,
    'state': phase.name,
    'from': from,
    'to': to,
    'identity': identity,
    'trainingRoot': trainingRoot,
    'entries': snapshot.toJson(),
    'training': [
      for (final file in training.files)
        {'name': file.name, 'before': file.before, 'after': file.after},
    ],
    'rowsChanged': training.rowsChanged,
    'booksBefore': booksBefore,
    'booksAfter': booksAfter,
    'backups': [
      for (final entry in backupByPath.entries)
        {'path': entry.key, 'plan': entry.value.toJson()},
    ],
  };

  @override
  void validate({required Directory documents, required Directory support}) {
    validateRelocationId(id);
    validateFolderRelocationPaths(documents, from, to);
    validateFolderParticipantPaths(documents, support, from, to);
    if (!p.isAbsolute(trainingRoot) ||
        p.normalize(trainingRoot) != trainingRoot ||
        trainingRoot.contains('\u0000')) {
      throw const RecoveryRequired('Unsupported training root spelling.');
    }
    final paths = snapshot.entries
        .where(
          (entry) =>
              entry.kind == DirectoryEntryKind.file &&
              p.extension(entry.path).toLowerCase() == '.pgn',
        )
        .map((entry) => entry.path)
        .toList();
    if (paths.length != backupByPath.length ||
        !Iterable<int>.generate(
          paths.length,
        ).every((i) => paths[i] == backupByPath.keys.elementAt(i))) {
      throw const RecoveryRequired('Folder backup inventory is incomplete.');
    }
    _validateFolderBackups(this, documents, support);
    if (relocateBookReferences(
          booksBefore,
          repertoireRoot: p.join(documents.path, 'repertoires'),
          from: from,
          to: to,
          directory: true,
        ) !=
        booksAfter) {
      throw const RecoveryRequired('Folder book snapshots disagree.');
    }
    for (final text in [
      booksBefore,
      booksAfter,
      for (final file in training.files) ...[file.before, file.after],
    ]) {
      if (text != null && !_safeText(text)) {
        throw const RecoveryRequired('Folder snapshot is not exact UTF-8.');
      }
    }
  }
}

Map<String, BackupMove> _decodeFolderBackups(Object? raw) {
  if (raw is! List) {
    throw const RecoveryRequired('Missing folder backup inventory.');
  }
  final backups = <String, BackupMove>{};
  for (final entry in raw) {
    _keys(entry, const {'path', 'plan'});
    final value = entry as Map<String, Object?>;
    final path = _string(value['path']);
    if (backups.containsKey(path) || value['plan'] is! Map<String, Object?>) {
      throw const RecoveryRequired('Invalid folder backup entry.');
    }
    backups[path] = BackupMove.fromJson(value['plan'] as Map<String, Object?>);
  }
  return backups;
}

void _validateFolderBackups(
  FolderRelocationRecord record,
  Directory documents,
  Directory support,
) {
  final ids = <String>{};
  final identities = <String>{};
  final roots = <String?>{};
  for (final entry in record.backupByPath.entries) {
    final plan = entry.value;
    final from = p.join(record.from, entry.key);
    final to = p.join(record.to, entry.key);
    if (plan.operationId != record.id ||
        plan.documentPath != to ||
        plan.rootPath != p.join(support.path, 'backups') ||
        plan.fromId != backupId(p.relative(from, from: documents.path)) ||
        plan.toId != backupId(p.relative(to, from: documents.path)) ||
        !ids.add(plan.fromId) ||
        !ids.add(plan.toId)) {
      throw const RecoveryRequired('Folder backup ownership disagrees.');
    }
    roots.add(plan.rootIdentity);
    final json = plan.toJson();
    for (final key in ['source', 'destination']) {
      final value = json[key] as Map<String, Object?>?;
      if (value != null &&
          (value['identity'] == plan.rootIdentity ||
              !identities.add(value['identity'] as String))) {
        throw const RecoveryRequired('Folder backup identities overlap.');
      }
    }
  }
  if (roots.length > 1) {
    throw const RecoveryRequired('Folder backup roots disagree.');
  }
}

void validateFolderRelocationPaths(
  Directory documents,
  String from,
  String to,
) {
  if (from == to ||
      p.isWithin(from, to) ||
      p.isWithin(to, from) ||
      [from, to].any(
        (path) =>
            !p.isAbsolute(path) ||
            path.contains('\u0000') ||
            p.normalize(path) != path ||
            !p.isWithin(documents.path, path),
      )) {
    throw const RecoveryRequired(
      'Relocation folders must be distinct, managed and nonoverlapping.',
    );
  }
}

/// Quarantined chapters retain the shared timestamp-token filename grammar.
/// Native callers use newCompoundId; arbitrary labels are valid only for moves.
void validateDeletionId(String id) {
  if (RegExp(r'^[0-9]{1,17}-[0-9a-f]+$').stringMatch(id) != id) {
    throw const RecoveryRequired(
      'A delete id must identify a recoverable chapter name.',
    );
  }
}

void validateRelocationId(String id) {
  if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').stringMatch(id) != id) {
    throw const RecoveryRequired('Unsupported relocation id.');
  }
}

void validateRelocationPaths(Directory documents, String from, String to) {
  if (from == to ||
      [from, to].any(
        (path) =>
            !p.isAbsolute(path) ||
            path.contains('\u0000') ||
            p.normalize(path) != path ||
            !p.isWithin(documents.path, path) ||
            p.extension(path).toLowerCase() != '.pgn',
      )) {
    throw const RecoveryRequired(
      'Relocation paths must be distinct managed PGNs.',
    );
  }
}

bool _safeText(String text) {
  // UTF-8 decoding consumes one leading BOM; restore it for exact comparison.
  final encoded = utf8.encode(text);
  final decoded = utf8.decode(encoded);
  return !text.contains('\u0000') &&
      (text.startsWith('\ufeff') ? '\ufeff$decoded' : decoded) == text;
}

void _keys(Object? value, Set<String> keys) {
  if (value is! Map<String, Object?> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const RecoveryRequired('Unsupported relocation schema.');
  }
}

String _string(Object? value) {
  if (value is! String) {
    throw const RecoveryRequired('Invalid relocation string.');
  }
  return value;
}

String? _nullable(Object? value) => value == null ? null : _string(value);

TrainingRepointPlan _decodeTraining(
  Map<String, Object?> json,
  Directory documents,
) {
  final from = _string(json['from']);
  final to = _string(json['to']);
  final trainingRoot = _string(json['trainingRoot']);
  final inputs = json['training'];
  const names = [reviewsFile, streaksFile, historyFile, attemptsFile];
  if (inputs is! List || inputs.length != names.length) {
    throw const RecoveryRequired('Incomplete relocation training read set.');
  }
  final before = <String, String?>{};
  final after = <String, String?>{};
  for (var i = 0; i < names.length; i++) {
    _keys(inputs[i], const {'name', 'before', 'after'});
    final file = inputs[i] as Map<String, Object?>;
    if (file['name'] != names[i]) {
      throw const RecoveryRequired('Unsupported relocation training order.');
    }
    before[names[i]] = _nullable(file['before']);
    after[names[i]] = _nullable(file['after']);
  }
  final training = TrainingRepointPlan.fromSnapshots(
    from: DocumentRef(from),
    to: DocumentRef(to),
    before: before,
    alternateFrom: DocumentRef(
      p.join(trainingRoot, p.relative(from, from: documents.path)),
    ),
    alternateTo: DocumentRef(
      p.join(trainingRoot, p.relative(to, from: documents.path)),
    ),
  );
  if (json['rowsChanged'] is! int ||
      json['rowsChanged'] != training.rowsChanged ||
      training.files.any((f) => f.after != after[f.name])) {
    throw const RecoveryRequired('Relocation training snapshots disagree.');
  }
  return training;
}

/// A folder may not relocate the metadata that owns or guards its own move.
/// Support may share Documents; only concrete participants are excluded.
void validateFolderParticipantPaths(
  Directory documents,
  Directory support,
  String from,
  String to,
) {
  bool overlaps(String a, String b) =>
      p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a);
  final participants = [
    for (final name in [
      'relocation-writes',
      'compound-writes',
      'unfinished-moves',
      'backups',
      'books.json',
      'repertoire-mutations',
    ])
      p.join(support.path, name),
    p.join(documents.path, '.cap-reference-history'),
    p.join(documents.path, 'repertoires', '.cap-repertoire-publications'),
  ];
  for (final endpoint in [from, to]) {
    if (p.equals(endpoint, support.path) ||
        p.isWithin(endpoint, support.path) ||
        participants.any((path) => overlaps(endpoint, path))) {
      throw const RecoveryRequired(
        'A folder move cannot relocate recovery metadata.',
      );
    }
  }
}
