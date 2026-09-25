import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup_relocation.dart';
import 'backups.dart';
import 'book_references.dart';
import 'document_ref.dart';
import 'relocation_notes.dart' show RecoveryRequired;
import 'training_records.dart';
import 'training_rows.dart';

enum FileRelocationKind { move, delete }

enum RelocationState { prepared, committing, complete, cancelled }

/// The durable immutable plan of a single file relocation. Only its phase
/// changes; decoding verifies every derived snapshot against captured inputs.
final class RelocationRecord {
  RelocationRecord({
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

  factory RelocationRecord.fromJson(
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
    final trainingRoot = _string(json['trainingRoot']);
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
    final state = RelocationState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    if (state == null || json['backup'] is! Map<String, Object?>) {
      throw const RecoveryRequired('Unsupported relocation state or backup.');
    }
    return RelocationRecord(
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

  final String id;
  final FileRelocationKind kind;
  final String from;
  final String to;
  final String trainingRoot;
  final String identity;
  final String hash;
  final TrainingRepointPlan training;
  final String? booksBefore;
  final String? booksAfter;
  final BackupMove backup;
  RelocationState state;

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
