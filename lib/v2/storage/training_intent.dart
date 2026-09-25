import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'document_ref.dart';
import 'training_payload.dart';

String trainingDigest(String text) =>
    sha256.convert(utf8.encode(text)).toString();
bool trainingId(Object? value) => value is String && _matches(_id, value);
final _id = RegExp(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}');
final _hash = RegExp(r'[0-9a-f]{64}');
bool _matches(RegExp pattern, String value) =>
    pattern.firstMatch(value)?.group(0) == value;
bool _digest(Object? value) => value is String && _matches(_hash, value);

/// Strict immutable acceptance and its optional pending file materialization.
/// Completed receipts keep command/order proofs but release full file copies.
final class TrainingIntent {
  TrainingIntent(
    this.core,
    this.state,
    this.payload,
    this.files,
    this.planDigest,
  );
  final Map<String, Object?> core;
  String state;
  String? payload;
  List<Map<String, Object?>>? files;
  String? planDigest;
  String get id => core['id']! as String;
  int get sequence => core['sequence']! as int;
  String? get previous => core['previous'] as String?;
  String? get dependency => core['dependency'] as String?;
  String get digest => core['digest']! as String;
  String get trainingRoot => core['trainingRoot']! as String;
  bool get complete => state == 'complete';
  Map<String, Revision> get sources => {
    for (final source
        in (core['sources']! as List<Object?>).cast<Map<String, Object?>>())
      source['path']! as String: Revision(
        source['hash']! as String,
        nativeIdentity: source['identity']! as String,
      ),
  };

  Map<String, Object?> toJson() => {
    ...core,
    'state': state,
    'payload': payload,
    'files': files,
    'planDigest': planDigest,
  };

  String digestPlan(List<Map<String, Object?>> files) =>
      trainingDigest(jsonEncode([core, files]));

  factory TrainingIntent.decode(
    Object? value,
    String id, {
    required String documents,
    required String support,
  }) {
    final json = _envelope(value, id, documents: documents, support: support);
    final core = {for (final field in _coreFields) field: json[field]};
    final state = json['state'];
    if (state == 'complete') {
      if (json['payload'] != null ||
          json['files'] != null ||
          !_digest(json['planDigest'])) {
        throw const FormatException('Invalid completed training receipt');
      }
      return TrainingIntent(
        core,
        'complete',
        null,
        null,
        json['planDigest']! as String,
      );
    }
    final payload = json['payload'];
    if (payload is! String || trainingDigest(payload) != json['digest']) {
      throw const FormatException('Invalid training payload digest');
    }
    final command = TrainingPayload.decode(payload);
    if (state is! String) throw const FormatException('Training phase');
    final record = TrainingIntent(core, state, payload, null, null);
    if (!record.sources.keys.toSet().containsAll(command.sources)) {
      throw const FormatException('Missing training source proof');
    }
    if (state == 'queued' &&
        json['files'] == null &&
        json['planDigest'] == null) {
      return record;
    }
    if (state != 'committing' ||
        json['files'] is! List<Object?> ||
        !_digest(json['planDigest'])) {
      throw const FormatException('Invalid training phase');
    }
    record.files = _validateFiles(json['files']! as List<Object?>);
    record.planDigest = json['planDigest']! as String;
    if (record.digestPlan(record.files!) != record.planDigest) {
      throw const FormatException('Invalid training plan digest');
    }
    _verifyPlan(command, record.files!);
    return record;
  }
}

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
const _fields = [..._coreFields, 'state', 'payload', 'files', 'planDigest'];

Map<String, Object?> trainingCore({
  required String id,
  required int sequence,
  required String? previous,
  required String? dependency,
  required String documents,
  required String support,
  required String trainingRoot,
  required Map<String, Revision> sources,
  required String payload,
}) {
  final paths = sources.keys.toList()..sort();
  return {
    'version': 1,
    'id': id,
    'sequence': sequence,
    'previous': previous,
    'dependency': dependency,
    'documentsRoot': documents,
    'supportRoot': support,
    'trainingRoot': trainingRoot,
    'sources': [
      for (final path in paths)
        {
          'path': path,
          'hash': sources[path]!.contentHash,
          'identity': sources[path]!.nativeIdentity,
        },
    ],
    'digest': trainingDigest(payload),
  };
}

bool _absolute(Object? value) =>
    value is String &&
    !value.contains('\u0000') &&
    p.isAbsolute(value) &&
    p.normalize(value) == value;

void _validateSources(Object? value, String documents, String configured) {
  if (value is! List<Object?>) throw const FormatException('Training sources');
  String? last;
  for (final entry in value) {
    if (entry is! Map<String, Object?> ||
        entry.length != 3 ||
        !entry.keys.toSet().containsAll({'path', 'hash', 'identity'}) ||
        !_absolute(entry['path']) ||
        !_digest(entry['hash']) ||
        entry['identity'] is! String ||
        (entry['identity']! as String).isEmpty ||
        (entry['identity']! as String).contains('\u0000')) {
      throw const FormatException('Invalid training source');
    }
    final path = entry['path']! as String;
    if ((!p.isWithin(documents, path) && !p.isWithin(configured, path)) ||
        p.extension(path).toLowerCase() != '.pgn' ||
        (last != null && last.compareTo(path) >= 0)) {
      throw const FormatException('Unmanaged or unordered training source');
    }
    last = path;
  }
}

List<Map<String, Object?>> _validateFiles(List<Object?> value) {
  if (value.length != trainingFileNames.length) {
    throw const FormatException('Training files');
  }
  return [
    for (final (index, entry) in value.indexed)
      _file(entry, trainingFileNames[index]),
  ];
}

Map<String, Object?> _file(Object? entry, String name) {
  if (entry is! Map<String, Object?> ||
      entry.length != 3 ||
      !entry.keys.toSet().containsAll({'name', 'before', 'after'}) ||
      entry['name'] != name) {
    throw const FormatException('Invalid training participant');
  }
  for (final field in ['before', 'after']) {
    trainingBytes(entry[field]);
  }
  return {'name': name, 'before': entry['before'], 'after': entry['after']};
}

Uint8List? trainingBytes(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Training bytes');
  final bytes = base64Decode(value);
  if (base64Encode(bytes) != value) {
    throw const FormatException('Noncanonical training bytes');
  }
  return bytes;
}

/// Both records are independently decoded before this transition proof runs.
bool trainingPredecessor(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final oldCore = {for (final key in _coreFields) key: before[key]};
  final newCore = {for (final key in _coreFields) key: after[key]};
  if (!const DeepCollectionEquality().equals(oldCore, newCore)) return false;
  return switch (before['state']) {
    'queued' => const {
      'queued',
      'committing',
      'complete',
    }.contains(after['state']),
    'committing' =>
      const {'committing', 'complete'}.contains(after['state']) &&
          before['planDigest'] == after['planDigest'],
    'complete' =>
      after['state'] == 'complete' &&
          before['planDigest'] == after['planDigest'],
    _ => false,
  };
}

void _verifyPlan(TrainingPayload command, List<Map<String, Object?>> files) {
  try {
    final before = {
      for (final file in files)
        file['name']! as String: trainingBytes(file['before']),
    };
    final planned = command.plan(before);
    for (final file in files) {
      if (!const ListEquality<int>().equals(
        planned[file['name']],
        trainingBytes(file['after']),
      )) {
        throw const FormatException(
          'Training plan does not implement its command',
        );
      }
    }
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Training plan cannot be reconstructed');
  }
}

Map<String, Object?> _envelope(
  Object? value,
  String id, {
  required String documents,
  required String support,
}) {
  if (value is! Map<String, Object?> ||
      value.length != _fields.length ||
      !value.keys.toSet().containsAll(_fields) ||
      !trainingId(id) ||
      value['id'] != id ||
      value['version'] is! int ||
      value['version'] != 1 ||
      value['sequence'] is! int ||
      (value['sequence']! as int) < 1 ||
      value['documentsRoot'] != documents ||
      value['supportRoot'] != support ||
      !_absolute(value['trainingRoot']) ||
      !_digest(value['digest'])) {
    throw const FormatException('Unknown training intent');
  }
  final sequence = value['sequence']! as int;
  if (sequence == 1
      ? value['previous'] != null
      : !trainingId(value['previous']) || value['previous'] == id) {
    throw const FormatException('Invalid training predecessor');
  }
  if (value['dependency'] != null &&
      (!trainingId(value['dependency']) || value['dependency'] == id)) {
    throw const FormatException('Invalid training dependency');
  }
  _validateSources(
    value['sources'],
    documents,
    value['trainingRoot']! as String,
  );
  return value;
}
