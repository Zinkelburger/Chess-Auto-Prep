import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../features/repertoires/models/repertoire_recovery_required.dart';

/// Compatibility boundary for v2 file relocations. Terminal metadata is
/// self-contained history: validate its complete schema, never today's PGN,
/// training files, book selections or backup directories. All other evidence
/// belongs to the v2 recovery owner and must block legacy recovery and actions.
Future<void> checkForeignRelocationHistory(
  Directory? notes, {
  required Directory? documents,
}) async {
  if (notes == null) return;
  try {
    final type = await FileSystemEntity.type(notes.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory || documents == null) {
      throw const FormatException(
        'Relocation recovery boundary is unavailable.',
      );
    }
    final roots = {
      p.normalize(p.absolute(documents.path)),
      p.normalize(await documents.resolveSymbolicLinks()),
    };
    final support = await notes.parent.resolveSymbolicLinks();
    await for (final entry in notes.list(followLinks: false)) {
      final id = p.basenameWithoutExtension(entry.path);
      if (entry is! File ||
          p.extension(entry.path) != '.json' ||
          !_matches(_operation, id) ||
          await FileSystemEntity.type(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FormatException('Unknown relocation metadata entry.');
      }
      _record(jsonDecode(await entry.readAsString()), id, roots, support);
    }
  } on Object catch (error) {
    throw RepertoireRecoveryRequired(
      notes.path,
      error,
      message:
          'A document relocation requires recovery. Reopen v2 before accessing documents or training. Its recovery files have been preserved.',
    );
  }
}

void _record(Object? raw, String id, Set<String> roots, String support) {
  final value = _fields(raw, const {
    'version',
    'id',
    'kind',
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
  if (value['version'] is! int ||
      value['version'] != 1 ||
      value['id'] != id ||
      !{'move', 'delete'}.contains(value['kind']) ||
      !{'complete', 'cancelled'}.contains(value['state']) ||
      !_nonempty(value['identity']) ||
      !_matches(_hash, value['hash']) ||
      value['rowsChanged'] is! int ||
      (value['rowsChanged']! as int) < 0) {
    throw const FormatException('Pending or unsupported relocation operation.');
  }
  final from = _document(value['from'], roots);
  final to = _document(value['to'], roots);
  if (value['kind'] == 'delete' &&
      to !=
          p.join(
            p.dirname(from),
            '.cap-pgn-history',
            '$id-${p.basename(from)}',
          )) {
    throw const FormatException('Invalid deleted document recovery path.');
  }
  if (value['trainingRoot'] is! String ||
      !_absolute(value['trainingRoot']! as String)) {
    throw const FormatException('Invalid relocation training root.');
  }
  final training = value['training'];
  if (training is! List || training.length != _trainingFiles.length) {
    throw const FormatException('Incomplete relocation training read set.');
  }
  for (var i = 0; i < training.length; i++) {
    final file = _fields(training[i], const {'name', 'before', 'after'});
    if (file['name'] != _trainingFiles[i] ||
        !_nullableText(file['before']) ||
        !_nullableText(file['after'])) {
      throw const FormatException('Invalid relocation training snapshot.');
    }
  }
  _books(value['booksBefore']);
  _books(value['booksAfter']);
  _backup(value['backup'], id, from, to, roots, support);
}

String _document(Object? value, Set<String> roots) {
  if (value is! String ||
      !_absolute(value) ||
      p.extension(value).toLowerCase() != '.pgn' ||
      !roots.any((root) => p.isWithin(root, value))) {
    throw const FormatException('Invalid relocation document path.');
  }
  return value;
}

void _backup(
  Object? raw,
  String id,
  String from,
  String to,
  Set<String> roots,
  String support,
) {
  final value = _fields(raw, const {
    'version',
    'operationId',
    'rootPath',
    'rootIdentity',
    'fromId',
    'toId',
    'documentPath',
    'asideName',
    'source',
    'destination',
    'indexAfter',
  });
  String backupId(String path) {
    final root = roots.firstWhere((root) => p.isWithin(root, path));
    final relative = p.posix.joinAll(p.split(p.relative(path, from: root)));
    return sha256.convert(utf8.encode(relative)).toString().substring(0, 16);
  }

  final fromId = backupId(from);
  final toId = backupId(to);
  if (value['version'] is! int ||
      value['version'] != 1 ||
      value['operationId'] != id ||
      value['rootPath'] != p.join(support, 'backups') ||
      value['fromId'] != fromId ||
      value['toId'] != toId ||
      fromId == toId ||
      value['documentPath'] != to ||
      value['asideName'] != '$toId.superseded-$id' ||
      (value['rootIdentity'] != null && !_nonempty(value['rootIdentity']))) {
    throw const FormatException('Invalid relocation backup ownership.');
  }
  final source = _inventory(value['source']);
  final destination = _inventory(value['destination']);
  final after = value['indexAfter'];
  if (!_nullableText(after) ||
      (source == null) != (after == null) ||
      (value['rootIdentity'] == null &&
          (source != null || destination != null)) ||
      (source != null && source.identity == destination?.identity)) {
    throw const FormatException('Inconsistent relocation backup participants.');
  }
  if (source != null && after is String) {
    final index = _index(after, source.files);
    if (source.index == null) {
      final versions = (index['versions']! as List)
          .cast<Map<String, Object?>>();
      final named = versions.map((version) => version['file']).toSet();
      if (source.files.where(_version).any((file) => !named.contains(file))) {
        throw const FormatException(
          'A rebuilt backup index omits captured versions.',
        );
      }
    }
    if (index['path'] != to ||
        (source.index != null &&
            after !=
                jsonEncode({
                  ..._index(source.index!, source.files),
                  'path': to,
                }))) {
      throw const FormatException(
        'Relocation backup index changes its captured history.',
      );
    }
  }
}

typedef _Inventory = ({String identity, String? index, Set<String> files});
_Inventory? _inventory(Object? raw) {
  if (raw == null) return null;
  final value = _fields(raw, const {'identity', 'index', 'files'});
  final entries = value['files'];
  if (!_nonempty(value['identity']) ||
      !_nullableText(value['index']) ||
      entries is! List) {
    throw const FormatException('Invalid backup inventory.');
  }
  final names = <String>{};
  String? previous;
  for (final raw in entries) {
    final file = _fields(raw, const {'name', 'sha256'});
    final name = file['name'];
    if (name is! String ||
        !_component(name) ||
        name == 'index.json' ||
        !_matches(_hash, file['sha256']) ||
        (previous != null && previous.compareTo(name) >= 0)) {
      throw const FormatException('Invalid backup file inventory.');
    }
    names.add(name);
    previous = name;
  }
  final index = value['index'] as String?;
  if (index != null) _index(index, names);
  return (identity: value['identity']! as String, index: index, files: names);
}

Map<String, Object?> _index(String text, Set<String> files) {
  final value = jsonDecode(
    text.startsWith('\ufeff') ? text.substring(1) : text,
  );
  if (value is! Map<String, Object?> ||
      value['path'] is! String ||
      value['versions'] is! List) {
    throw const FormatException('Invalid captured backup index.');
  }
  final names = <String>{};
  for (final entry in value['versions']! as List) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException('Invalid captured backup version.');
    }
    final file = entry['file'];
    final time = entry['time'];
    final size = entry['size'];
    if (file is! String ||
        !_component(file) ||
        !_version(file) ||
        !files.contains(file) ||
        !names.add(file) ||
        time is! String ||
        DateTime.tryParse(time) == null ||
        size is! int ||
        size < 0 ||
        !_matches(_hash, entry['hash'])) {
      throw const FormatException('Invalid captured backup version fields.');
    }
  }
  return value;
}

/// Books v1 permits unknown metadata, duplicate entries and missing optional
/// selectors. Known fields still validate completely, even for terminal notes.
void _books(Object? raw) {
  if (raw == null) return;
  if (raw is! String) {
    throw const FormatException('Invalid captured books text.');
  }
  final value = jsonDecode(raw);
  if (value is! Map<String, Object?> ||
      value['version'] != 1 ||
      value['books'] is! List ||
      (value['active'] != null && value['active'] is! String)) {
    throw const FormatException('Invalid captured books schema.');
  }
  for (final book in value['books']! as List) {
    if (book is! Map<String, Object?> ||
        book['id'] is! String ||
        book['name'] is! String) {
      throw const FormatException('Invalid captured book.');
    }
    for (final field in ['repertoires', 'chapters']) {
      if (!book.containsKey(field)) continue;
      final entries = book[field];
      if (entries is! List) {
        throw const FormatException('Invalid captured book selectors.');
      }
      for (final entry in entries) {
        if (field == 'repertoires') {
          if (!_relative(entry)) {
            throw const FormatException('Invalid captured book folder.');
          }
        } else if (entry is! Map<String, Object?> ||
            !_relative(entry['path']) ||
            (entry['section'] != null && entry['section'] is! String)) {
          throw const FormatException('Invalid captured book chapter.');
        }
      }
    }
  }
}

Map<String, Object?> _fields(Object? raw, Set<String> fields) {
  if (raw is! Map<String, Object?> ||
      raw.length != fields.length ||
      !raw.keys.toSet().containsAll(fields)) {
    throw const FormatException('Unsupported relocation metadata fields.');
  }
  return raw;
}

bool _absolute(String path) =>
    !path.contains('\u0000') && p.isAbsolute(path) && p.normalize(path) == path;
bool _nonempty(Object? value) => value is String && value.isNotEmpty;
bool _nullableText(Object? value) => value == null || value is String;
bool _matches(RegExp pattern, Object? value) =>
    value is String && pattern.stringMatch(value) == value;
bool _component(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains(RegExp(r'[/\\\x00-\x1f]'));
bool _relative(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value != '.' &&
    !value.contains('\\') &&
    !p.posix.isAbsolute(value) &&
    !p.windows.isAbsolute(value) &&
    p.posix.normalize(value) == value &&
    !p.posix.split(value).contains('..');
final _operation = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
final _hash = RegExp(r'^[0-9a-f]{64}$');
const _trainingFiles = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];

bool _version(String name) => name.endsWith('.pgn') || name.endsWith('.pgn.gz');
