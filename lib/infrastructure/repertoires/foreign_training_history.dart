import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../features/repertoires/models/repertoire_recovery_required.dart';
import '../../utils/training_csv.dart';
import 'foreign_recovery_copies.dart';

/// V1 never replays v2 training commands. A compact completed receipt is
/// compatible history; any pending or unverified evidence blocks access.
Future<void> checkForeignTrainingHistory(
  Directory? notes, {
  required Directory? documents,
}) async {
  if (notes == null) return;
  try {
    final type = await FileSystemEntity.type(notes.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory || documents == null) {
      throw const FormatException('Training recovery boundary is unavailable.');
    }
    final root = p.normalize(await documents.resolveSymbolicLinks());
    final support = p.normalize(await notes.parent.resolveSymbolicLinks());
    final current = <Map<String, Object?>>[];
    await checkForeignRecoveryHistory(
      notes,
      validate: (value, id, terminal) {
        final record = _record(value, id, root, support, terminal: terminal);
        if (terminal) current.add(record);
      },
      predecessor: _predecessor,
    );
    current.sort(
      (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int),
    );
    String? previous;
    final earlier = <String>{};
    for (var index = 0; index < current.length; index++) {
      final record = current[index];
      if (record['sequence'] != index + 1 || record['previous'] != previous) {
        throw const FormatException('Incomplete training command history.');
      }
      if (record['dependency'] != null &&
          !earlier.contains(record['dependency'])) {
        throw const FormatException('Missing accepted training predecessor.');
      }
      previous = record['id'] as String;
      earlier.add(previous);
    }
  } on Object catch (error) {
    throw RepertoireRecoveryRequired(
      notes.path,
      error,
      message:
          'A training command requires recovery. Reopen v2 before accessing '
          'documents or training. Its recovery files have been preserved.',
    );
  }
}

Map<String, Object?> _record(
  Object? raw,
  String id,
  String documents,
  String support, {
  required bool terminal,
}) {
  final value = _fields(raw, {
    ..._coreFields,
    'state',
    'payload',
    'files',
    'planDigest',
  });
  final sequence = value['sequence'];
  final previous = value['previous'];
  final dependency = value['dependency'];
  if (value['version'] is! int ||
      value['version'] != 1 ||
      value['id'] != id ||
      !_matches(_id, id) ||
      sequence is! int ||
      sequence < 1 ||
      (sequence == 1
          ? previous != null
          : !_matches(_id, previous) || previous == id) ||
      (dependency != null &&
          (!_matches(_id, dependency) || dependency == id)) ||
      value['documentsRoot'] != documents ||
      value['supportRoot'] != support ||
      !_absolute(value['trainingRoot']) ||
      !_matches(_hash, value['digest'])) {
    throw const FormatException('Invalid training command identity.');
  }
  _sources(value['sources'], documents, value['trainingRoot'] as String);
  switch (value['state']) {
    case 'complete':
      if (value['payload'] != null ||
          value['files'] != null ||
          !_matches(_hash, value['planDigest'])) {
        throw const FormatException('Invalid completed training receipt.');
      }
    case 'queued' || 'committing':
      if (terminal) throw const FormatException('Pending training command.');
      final payload = value['payload'];
      if (payload is! String || _digest(payload) != value['digest']) {
        throw const FormatException('Invalid training command payload.');
      }
      _payload(payload, value['sources'] as List);
      if (value['state'] == 'queued') {
        if (value['files'] != null || value['planDigest'] != null) {
          throw const FormatException(
            'Queued command contains a publication plan.',
          );
        }
      } else {
        final files = _files(value['files']);
        if (_digest(jsonEncode([_core(value), files])) != value['planDigest']) {
          throw const FormatException('Invalid training publication proof.');
        }
      }
    default:
      throw const FormatException('Unknown training command state.');
  }
  return value;
}

void _sources(Object? raw, String documents, String alias) {
  if (raw is! List) throw const FormatException('Invalid training sources.');
  String? previous;
  for (final entry in raw) {
    final source = _fields(entry, const {'path', 'hash', 'identity'});
    final path = source['path'];
    final identity = source['identity'];
    if (!_absolute(path) ||
        path is! String ||
        p.extension(path).toLowerCase() != '.pgn' ||
        !(p.isWithin(documents, path) || p.isWithin(alias, path)) ||
        (previous != null && previous.compareTo(path) >= 0) ||
        !_matches(_hash, source['hash']) ||
        identity is! String ||
        identity.isEmpty ||
        identity.contains('\u0000')) {
      throw const FormatException('Invalid training source observation.');
    }
    previous = path;
  }
}

List<Map<String, Object?>> _files(Object? raw) {
  if (raw is! List || raw.length != _fileNames.length) {
    throw const FormatException('Incomplete training publication read set.');
  }
  final files = <Map<String, Object?>>[];
  for (var index = 0; index < raw.length; index++) {
    final file = _fields(raw[index], const {'name', 'before', 'after'});
    if (file['name'] != _fileNames[index]) {
      throw const FormatException('Unknown training participant.');
    }
    for (final key in ['before', 'after']) {
      final bytes = file[key];
      if (bytes == null) continue;
      if (bytes is! String || base64Encode(base64Decode(bytes)) != bytes) {
        throw const FormatException('Invalid training participant bytes.');
      }
    }
    files.add({
      'name': file['name'],
      'before': file['before'],
      'after': file['after'],
    });
  }
  return files;
}

void _payload(String text, List sources) {
  if (utf8.decode(utf8.encode(text)) != text || text.contains('\u0000')) {
    throw const FormatException('Invalid training command text.');
  }
  final value = jsonDecode(text);
  final paths = {for (final source in sources) (source as Map)['path']};
  if (value is! List || value.isEmpty) {
    throw const FormatException('Invalid training command shape.');
  }
  if (value.first == 'attempt') {
    if (value.length != 2 || value[1] is! String || sources.isEmpty) {
      throw const FormatException('Invalid accepted attempt.');
    }
    final attempt = _fields(jsonDecode(value[1] as String), const {
      'repertoireId',
      'lineId',
      'moveIndex',
      'fen',
      'playedSan',
      'expectedSan',
      'correct',
      'phase',
      'timestampUtc',
    });
    if (!paths.contains(attempt['repertoireId']) ||
        attempt['moveIndex'] is! int ||
        attempt['correct'] is! bool ||
        !const {
          'learning',
          'drilling',
          'replaying',
        }.contains(attempt['phase']) ||
        ![
          'repertoireId',
          'lineId',
          'fen',
          'playedSan',
          'expectedSan',
          'phase',
          'timestampUtc',
        ].every((key) => _text(attempt[key])) ||
        DateTime.tryParse(attempt['timestampUtc'] as String) == null) {
      throw const FormatException('Invalid accepted attempt fields.');
    }
  } else if (value.first == 'write') {
    if (value.length != 4 || value.skip(1).any((part) => part is! List)) {
      throw const FormatException('Invalid accepted training rows.');
    }
    for (var index = 1; index <= 2; index++) {
      final changes = value[index] as List;
      final identities = <String>{};
      for (final change in changes) {
        if (change is! List ||
            change.length != 2 ||
            (change[0] != null && change[0] is! String) ||
            change[1] is! String) {
          throw const FormatException('Invalid accepted row change.');
        }
        final after = _row(change[1] as String, index == 1 ? 11 : 5, paths);
        if (!identities.add(
          jsonEncode(after.take(index == 1 ? 2 : 3).toList()),
        )) {
          throw const FormatException('Duplicate accepted row change.');
        }
        if (change[0] != null) {
          final before = _row(change[0] as String, index == 1 ? 11 : 5, paths);
          if (before[0] != after[0] ||
              before[1] != after[1] ||
              (index == 2 && before[2] != after[2])) {
            throw const FormatException('Accepted row identity changed.');
          }
        }
      }
    }
    for (final row in value[3] as List) {
      if (row is! List ||
          row.length != 6 ||
          row.any((cell) => !_text(cell)) ||
          !paths.contains(row[0]) ||
          (row[1] as String).isEmpty ||
          DateTime.tryParse(row[2] as String) == null ||
          !const {'0', '1'}.contains(row[4]) ||
          !const {'trainer', 'marked'}.contains(row[5])) {
        throw const FormatException('Invalid accepted history row.');
      }
    }
    if (sources.isEmpty &&
        value.skip(1).any((part) => (part as List).isNotEmpty)) {
      throw const FormatException('Accepted rows have no source observations.');
    }
  } else {
    throw const FormatException('Unknown training command.');
  }
}

List<String> _row(String text, int width, Set<Object?> paths) {
  final cells = decodeTrainingRow(text, width);
  if (cells.length != width ||
      cells.any((cell) => !_text(cell)) ||
      !paths.contains(cells[0])) {
    throw const FormatException('Invalid accepted row fields.');
  }
  final valid = width == 11
      ? double.tryParse(cells[3]) != null &&
            double.tryParse(cells[4]) != null &&
            int.tryParse(cells[8]) != null &&
            int.tryParse(cells[9]) != null &&
            const {'true', 'false'}.contains(cells[10])
      : int.tryParse(cells[2]) != null &&
            int.tryParse(cells[3]) != null &&
            const {'0', '1'}.contains(cells[4]);
  if (!valid) throw const FormatException('Invalid accepted row values.');
  return cells;
}

bool _text(Object? value) =>
    value is String &&
    !value.contains('\u0000') &&
    utf8.decode(utf8.encode(value)) == value;

bool _predecessor(Map<String, Object?> previous, Map<String, Object?> current) {
  const equal = DeepCollectionEquality();
  if (!equal.equals(_core(previous), _core(current))) return false;
  return switch ((previous['state'], current['state'])) {
    ('queued', 'queued') => previous['payload'] == current['payload'],
    ('queued', 'committing' || 'complete') => true,
    ('committing', 'committing') => equal.equals(previous, current),
    ('committing', 'complete') =>
      previous['planDigest'] == current['planDigest'],
    ('complete', 'complete') => equal.equals(previous, current),
    _ => false,
  };
}

Map<String, Object?> _core(Map<String, Object?> value) => {
  for (final key in _coreFields) key: value[key],
};

Map<String, Object?> _fields(Object? value, Set<String> fields) {
  if (value is! Map<String, Object?> ||
      value.length != fields.length ||
      !value.keys.every(fields.contains)) {
    throw const FormatException('Unsupported training recovery fields.');
  }
  return value;
}

bool _absolute(Object? path) =>
    path is String &&
    !path.contains('\u0000') &&
    p.isAbsolute(path) &&
    p.normalize(path) == path;
bool _matches(RegExp pattern, Object? value) =>
    value is String && pattern.firstMatch(value)?.group(0) == value;
String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

const _coreFields = [
  'version',
  'id',
  'sequence',
  'previous',
  'dependency',
  'documentsRoot',
  'supportRoot',
  'trainingRoot',
  'sources',
  'digest',
];
const _fileNames = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];
final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
final _hash = RegExp(r'^[a-f0-9]{64}$');
