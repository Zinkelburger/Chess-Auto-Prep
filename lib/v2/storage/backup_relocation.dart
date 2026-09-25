import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'backups.dart';
import 'relocation_notes.dart' show RecoveryRequired;

enum BackupMoveStep { destinationAside, sourceMoved, indexPublished }

/// Exact ownership transfer embedded in the caller's relocation journal.
/// Directory identities and the complete file inventory survive serialization;
/// recovery never discovers a new intended history from the current paths.
final class BackupMove {
  BackupMove._({
    required this.operationId,
    required this.rootPath,
    required this.rootIdentity,
    required this.fromId,
    required this.toId,
    required this.documentPath,
    required _DirectoryPlan? source,
    required _DirectoryPlan? destination,
    required this.indexAfter,
  }) : _source = source,
       _destination = destination;

  factory BackupMove.fromJson(Map<String, Object?> json) {
    _keys(json, const {
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
    if (json['version'] is! int || json['version'] != 1)
      _refuse('Unsupported backup move version.');
    final move = BackupMove._(
      operationId: _string(json['operationId']),
      rootPath: _string(json['rootPath']),
      rootIdentity: _nullableString(json['rootIdentity']),
      fromId: _string(json['fromId']),
      toId: _string(json['toId']),
      documentPath: _string(json['documentPath']),
      source: _DirectoryPlan.decode(json['source']),
      destination: _DirectoryPlan.decode(json['destination']),
      indexAfter: _nullableString(json['indexAfter']),
    );
    move._validate();
    if (json['asideName'] != move.asideName) _refuse('Invalid backup aside.');
    return move;
  }

  final String operationId;
  final String rootPath;
  final String? rootIdentity;
  final String fromId;
  final String toId;
  final String documentPath;
  final _DirectoryPlan? _source;
  final _DirectoryPlan? _destination;
  final String? indexAfter;
  String get asideName => '$toId.superseded-$operationId';

  Map<String, Object?> toJson() => {
    'version': 1,
    'operationId': operationId,
    'rootPath': rootPath,
    'rootIdentity': rootIdentity,
    'fromId': fromId,
    'toId': toId,
    'documentPath': documentPath,
    'asideName': asideName,
    'source': _source?.toJson(),
    'destination': _destination?.toJson(),
    'indexAfter': indexAfter,
  };

  void _validate() {
    if (_id.stringMatch(fromId) != fromId ||
        _id.stringMatch(toId) != toId ||
        fromId == toId ||
        _operation.stringMatch(operationId) != operationId ||
        !_absolute(rootPath) ||
        !_absolute(documentPath) ||
        (rootIdentity != null && rootIdentity!.isEmpty) ||
        (rootIdentity == null && (_source != null || _destination != null)) ||
        (_source == null) != (indexAfter == null) ||
        (_source != null && _source.identity == _destination?.identity)) {
      _refuse('Invalid backup ownership plan.');
    }
    final after = indexAfter;
    if (after != null) {
      final index = _index(after, _source!.files);
      if (index['path'] != documentPath) _refuse('Invalid backup target path.');
      final before = _source.index;
      if (before == null) {
        final named = {
          for (final entry in index['versions']! as List)
            (entry as Map)['file'],
        };
        final versions = _source.files.keys.where(_version).toSet();
        if (named.length != versions.length || !named.containsAll(versions)) {
          _refuse('Rebuilt backup index omits recorded versions.');
        }
      }
      if (before != null &&
          after !=
              jsonEncode({
                ..._index(before, _source.files),
                'path': documentPath,
              })) {
        _refuse('Backup index changes more than its owner path.');
      }
    }
  }
}

/// The caller holds the profile/domain and backup namespace guards. Planning
/// reads only; applying completes forward and throws on every unproven state.
final class BackupRelocation {
  BackupRelocation(
    this.root, {
    Future<void> Function(String) synchronize = syncDirectory,
  }) : _synchronize = synchronize;
  final Directory root;
  final Future<void> Function(String) _synchronize;
  Future<void> _sync(String path) async {
    if (!Platform.isWindows) await _synchronize(path);
  }

  Future<BackupMove> planMove({
    required String fromId,
    required String toId,
    required String documentPath,
    required String operationId,
  }) => _checked(() async {
    final rootPath = p.normalize(p.absolute(root.path));
    // Validate components before using any of them in a filesystem path.
    BackupMove._(
      operationId: operationId,
      rootPath: rootPath,
      rootIdentity: null,
      fromId: fromId,
      toId: toId,
      documentPath: documentPath,
      source: null,
      destination: null,
      indexAfter: null,
    )._validate();
    final identity = await _directoryIdentity(rootPath);
    final source = await _snapshot(p.join(rootPath, fromId));
    final destination = await _snapshot(p.join(rootPath, toId));
    final aside = p.join(rootPath, '$toId.superseded-$operationId');
    if (await _directoryIdentity(aside) != null)
      _refuse('Backup aside already exists.');
    final String? after;
    if (source == null) {
      after = null;
    } else if (source.index case final index?) {
      after = jsonEncode({
        ..._index(index, source.files),
        'path': documentPath,
      });
    } else {
      after = jsonEncode({
        'path': documentPath,
        'versions': await _rebuild(p.join(rootPath, fromId), source),
      });
    }
    final move = BackupMove._(
      operationId: operationId,
      rootPath: rootPath,
      rootIdentity: identity,
      fromId: fromId,
      toId: toId,
      documentPath: documentPath,
      source: source,
      destination: destination,
      indexAfter: after,
    );
    await validateMove(move, allowAfter: false);
    return move;
  });

  Future<void> validateMove(BackupMove move, {bool allowAfter = true}) =>
      _checked(() async {
        move._validate();
        if (p.normalize(p.absolute(root.path)) != move.rootPath ||
            await _directoryIdentity(move.rootPath) != move.rootIdentity) {
          _refuse('The backup root changed.');
        }
        final from = await _snapshot(p.join(move.rootPath, move.fromId));
        final to = await _snapshot(p.join(move.rootPath, move.toId));
        final aside = await _snapshot(p.join(move.rootPath, move.asideName));
        final initial =
            _same(from, move._source) &&
            _same(to, move._destination) &&
            aside == null;
        final separated =
            _same(from, move._source) &&
            to == null &&
            _same(aside, move._destination);
        final landed =
            from == null &&
            _same(to, move._source, indexAfter: move.indexAfter) &&
            _same(aside, move._destination);
        if (!initial && !(allowAfter && (separated || landed))) {
          _refuse('Backup ownership or its recorded files changed.');
        }
        if (move.indexAfter case final after?) {
          final sourceAt = from != null ? move.fromId : move.toId;
          await _verifyVersions(p.join(move.rootPath, sourceAt), after);
        }
      });

  Future<void> applyMove(
    BackupMove move, {
    Future<void> Function(BackupMoveStep)? testHook,
  }) => _checked(() async {
    await validateMove(move);
    if (move.rootIdentity == null) return;
    // A previous rename may have landed but lost its flush acknowledgement.
    await _sync(move.rootPath);
    final from = p.join(move.rootPath, move.fromId);
    final to = p.join(move.rootPath, move.toId);
    final aside = p.join(move.rootPath, move.asideName);
    if (move._destination != null && await _directoryIdentity(aside) == null) {
      await movePathNoReplace(to, aside);
      await _sync(move.rootPath);
      await testHook?.call(BackupMoveStep.destinationAside);
    }
    if (move._source != null && await _directoryIdentity(from) != null) {
      await movePathNoReplace(from, to);
      await _sync(move.rootPath);
      await testHook?.call(BackupMoveStep.sourceMoved);
    }
    await validateMove(move);
    if (move.indexAfter case final after?) {
      final path = p.join(to, _indexName);
      final current = await _fileText(path);
      if (current != after) {
        await replaceFile(path, utf8.encode(after));
      }
      await _sync(to);
      await testHook?.call(BackupMoveStep.indexPublished);
    }
    await validateMove(move);
  });
}

final class _DirectoryPlan {
  _DirectoryPlan(this.identity, this.index, Map<String, String> files)
    : files = Map.unmodifiable(files);
  final String identity;
  final String? index;
  final Map<String, String> files;

  static _DirectoryPlan? decode(Object? value) {
    if (value == null) return null;
    if (value is! Map<String, Object?>) _refuse('Invalid backup directory.');
    _keys(value, const {'identity', 'index', 'files'});
    final identity = _string(value['identity']);
    final index = _nullableString(value['index']);
    final entries = value['files'];
    if (identity.isEmpty || entries is! List)
      _refuse('Invalid backup inventory.');
    final files = <String, String>{};
    String? previous;
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) _refuse('Invalid backup file.');
      _keys(entry, const {'name', 'sha256'});
      final name = _string(entry['name']);
      final hash = _string(entry['sha256']);
      if (!_component(name) ||
          name == _indexName ||
          _hash.stringMatch(hash) != hash ||
          (previous != null && previous.compareTo(name) >= 0)) {
        _refuse('Invalid backup file identity.');
      }
      files[name] = hash;
      previous = name;
    }
    if (index != null) _index(index, files);
    return _DirectoryPlan(identity, index, files);
  }

  Map<String, Object?> toJson() => {
    'identity': identity,
    'index': index,
    'files': [
      for (final name in files.keys.toList()..sort())
        {'name': name, 'sha256': files[name]},
    ],
  };
}

Future<_DirectoryPlan?> _snapshot(String path) async {
  final identity = await _directoryIdentity(path);
  if (identity == null) return null;
  final files = <String, String>{};
  String? index;
  await for (final entry in Directory(path).list(followLinks: false)) {
    final name = p.basename(entry.path);
    if (entry is! File ||
        !_component(name) ||
        name == p.basename(temporaryPathFor(_indexName))) {
      _refuse('Unsupported backup entry: ${entry.path}.');
    }
    final observed = await observeFile(entry.path);
    if (observed.status != 0 ||
        observed.bytes == null ||
        observed.sha256Hex == null) {
      _refuse('Cannot read backup entry: ${entry.path}.');
    }
    if (name == _indexName) {
      index = _exactText(observed.bytes!);
    } else {
      files[name] = observed.sha256Hex!;
    }
  }
  if (index != null) {
    _index(index, files);
    await _verifyVersions(path, index);
  }
  if (await _directoryIdentity(path) != identity)
    _refuse('Backup directory changed during read.');
  return _DirectoryPlan(identity, index, files);
}

bool _same(
  _DirectoryPlan? actual,
  _DirectoryPlan? expected, {
  String? indexAfter,
}) {
  if (actual == null || expected == null) return actual == expected;
  return actual.identity == expected.identity &&
      (actual.index == expected.index ||
          (indexAfter != null && actual.index == indexAfter)) &&
      actual.files.length == expected.files.length &&
      actual.files.entries.every((e) => expected.files[e.key] == e.value);
}

Map<String, Object?> _index(String text, Map<String, String> files) {
  final json = jsonDecode(text.startsWith('\ufeff') ? text.substring(1) : text);
  if (json is! Map<String, Object?> ||
      json['path'] is! String ||
      json['versions'] is! List) {
    _refuse('Malformed backup index.');
  }
  final named = <String>{};
  for (final entry in json['versions']! as List) {
    if (entry is! Map<String, Object?>) _refuse('Malformed backup version.');
    final version = BackupVersion.fromJson(entry);
    if (!_component(version.file) ||
        !_version(version.file) ||
        !files.containsKey(version.file) ||
        !named.add(version.file) ||
        version.size < 0 ||
        _hash.stringMatch(version.hash) != version.hash) {
      _refuse('Invalid backup version reference.');
    }
  }
  return json;
}

Future<void> _verifyVersions(String path, String index) async {
  final json =
      jsonDecode(index.startsWith('\ufeff') ? index.substring(1) : index)
          as Map<String, Object?>;
  for (final entry in json['versions']! as List) {
    final version = BackupVersion.fromJson(entry as Map<String, Object?>);
    final observed = await observeFile(p.join(path, version.file));
    if (observed.status != 0 || observed.bytes == null)
      _refuse('Backup version disappeared.');
    final bytes = versionBytes(observed.bytes!);
    if (bytes.length != version.size ||
        sha256.convert(bytes).toString() != version.hash) {
      _refuse('Backup version content does not match its index.');
    }
  }
}

Future<List<Map<String, Object?>>> _rebuild(
  String path,
  _DirectoryPlan source,
) async {
  final versions = <BackupVersion>[];
  for (final name in source.files.keys.where(_version)) {
    final file = File(p.join(path, name));
    final observed = await observeFile(file.path);
    if (observed.status != 0 || observed.sha256Hex != source.files[name])
      _refuse('Backup version changed.');
    final bytes = versionBytes(observed.bytes!);
    final stamp = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\d{3,6})Z-',
    ).firstMatch(name);
    final time = stamp == null
        ? null
        : DateTime.tryParse(
            '${stamp[1]}-${stamp[2]}-${stamp[3]}T${stamp[4]}:${stamp[5]}:${stamp[6]}.${stamp[7]}Z',
          );
    versions.add(
      BackupVersion(
        file: name,
        time: time ?? (await file.stat()).modified.toUtc(),
        size: bytes.length,
        hash: sha256.convert(bytes).toString(),
      ),
    );
  }
  versions.sort((a, b) {
    final time = a.time.compareTo(b.time);
    return time == 0 ? a.file.compareTo(b.file) : time;
  });
  return [for (final version in versions) version.toJson()];
}

Future<String?> _directoryIdentity(String path) async {
  final observed = await observeDirectory(path);
  if (observed.status == 1) return null;
  if (observed.status != 0 || observed.identity == null)
    _refuse('Cannot identify backup directory: $path.');
  return observed.identity;
}

Future<String?> _fileText(String path) async {
  final observed = await observeFile(path);
  if (observed.status == 1) return null;
  if (observed.status != 0 || observed.bytes == null)
    _refuse('Cannot read backup index: $path.');
  return _exactText(observed.bytes!);
}

String _exactText(List<int> bytes) {
  final text = utf8.decode(bytes);
  final marked =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  return marked ? '\ufeff$text' : text;
}

Future<T> _checked<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on RecoveryRequired {
    rethrow;
  } on Object catch (error) {
    throw RecoveryRequired('Backup relocation: $error');
  }
}

Never _refuse(String detail) => throw RecoveryRequired(detail);
void _keys(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys))
    _refuse('Unsupported backup metadata fields.');
}

String _string(Object? value) {
  if (value is! String) _refuse('Invalid backup metadata string.');
  return value;
}

String? _nullableString(Object? value) => value == null ? null : _string(value);
bool _absolute(String value) =>
    !value.contains('\u0000') &&
    p.isAbsolute(value) &&
    p.normalize(value) == value;
bool _component(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains(RegExp(r'[/\\\x00-\x1f]'));
bool _version(String name) => name.endsWith('.pgn') || name.endsWith('.pgn.gz');
final _id = RegExp(r'^[0-9a-f]{16}$');
final _hash = RegExp(r'^[0-9a-f]{64}$');
final _operation = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
const _indexName = 'index.json';
