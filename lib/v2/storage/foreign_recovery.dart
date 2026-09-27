import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'relocation_notes.dart';

/// Recognizes the retained v1 directory-move and publication receipts without
/// replaying or changing them. The caller holds the canonical repertoire domain.
/// Completed history may outlive its original paths, so only its metadata is
/// checked. Pending, unknown or unreadable metadata requires the v1 owner.
Future<void> refuseV1Recovery(Directory documents, Directory support) async {
  try {
    await _moves(Directory(p.join(support.path, 'repertoire-mutations')));
    final root = Directory(p.join(documents.path, 'repertoires'));
    await _directory(root);
    await _publications(Directory(p.join(root.path, _publicationFolder)));
  } on FileSystemException catch (error) {
    throw RecoveryRequired('Cannot inspect v1 recovery metadata: $error');
  } on FormatException catch (error) {
    throw RecoveryRequired(
      'Reopen v1 to inspect or recover its retained operation before accessing Documents: ${error.message}',
    );
  }
}

const _publicationFolder = '.cap-repertoire-publications';
final _id = RegExp(r'^[0-9]+-[0-9a-f]+$');

Never _invalid(String path) => throw FormatException(path);

Future<bool> _directory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  if (type != FileSystemEntityType.directory) _invalid(directory.path);
  return true;
}

Future<Map<String, Object?>> _read(File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    _invalid(file.path);
  }
  final value = jsonDecode(await file.readAsString());
  if (value is! Map<String, Object?>) _invalid(file.path);
  return value;
}

/// The optional kind field predates trash/restore support. Its absence means
/// an ordinary move in the v1 format, not an unknown protocol.
Future<void> _moves(Directory directory) async {
  if (!await _directory(directory)) return;
  final records = <String, Map<String, Object?>>{};
  await for (final entry in directoryEntries(directory, followLinks: false)) {
    final id = p.basenameWithoutExtension(entry.path);
    if (entry is! File ||
        p.extension(entry.path) != '.json' ||
        !_id.hasMatch(id)) {
      _invalid(entry.path);
    }
    final record = await _read(entry);
    if (!_envelope(record, id, {
          'version',
          'id',
          'from',
          'to',
          'identity',
          'state',
          'kind',
          'recoveryId',
        }) ||
        !_strings(record, ['from', 'to', 'identity']) ||
        !{'move', 'trash', 'restore'}.contains(record['kind'] ?? 'move') ||
        !{'completed', 'cancelled'}.contains(record['state'])) {
      _invalid(entry.path);
    }
    final recovery = record['recoveryId'];
    if (recovery != null && (recovery is! String || !_id.hasMatch(recovery))) {
      _invalid(entry.path);
    }
    records[id] = record;
  }
  final restored = <String>{};
  for (final record in records.values.where((r) => r['kind'] == 'restore')) {
    final recovery = record['recoveryId'];
    final original = records[recovery];
    if (recovery is! String ||
        original == null ||
        original['kind'] != 'trash' ||
        original['state'] != 'completed' ||
        record['from'] != original['to'] ||
        record['identity'] != original['identity'] ||
        (record['state'] == 'completed' && !restored.add(recovery))) {
      _invalid('${directory.path}: restore ${record['id']}');
    }
  }
}

Future<void> _publications(Directory directory) async {
  if (!await _directory(directory)) return;
  await for (final entry in directoryEntries(directory, followLinks: false)) {
    final id = p.basename(entry.path);
    if (entry is! Directory || !_id.hasMatch(id)) _invalid(entry.path);
    File? manifest;
    await for (final child in directoryEntries(entry, followLinks: false)) {
      switch (p.basename(child.path)) {
        case 'publication.json' when child is File:
          manifest = child;
        case 'source.pgn' when child is File:
          break;
        case 'payload' when child is Directory:
          await _privatePayload(child);
        default:
          // In particular, an interrupted atomic receipt replacement cannot
          // masquerade as a private preparation with no publication intent.
          _invalid(child.path);
      }
    }
    // V1 creates its batch/payload/source before the first manifest and writes
    // a pending manifest before any publication rename. With no other metadata,
    // absence is a private preparation that this reader must leave alone.
    if (manifest == null) continue;
    final record = await _read(manifest);
    if (!_envelope(record, id, {
          'version',
          'id',
          'name',
          'identity',
          'state',
          'files',
        }) ||
        !_strings(record, ['name', 'identity']) ||
        !_component(record['name'] as String, trimmed: true) ||
        record['name'] == _publicationFolder ||
        !{'staged', 'completed', 'cancelled'}.contains(record['state'])) {
      _invalid(manifest.path);
    }
    _chapters(record['files'], manifest.path);
  }
}

Future<void> _privatePayload(Directory directory) async {
  await for (final entry in directoryEntries(
    directory,
    recursive: true,
    followLinks: false,
  )) {
    if (entry is! File && entry is! Directory) _invalid(entry.path);
  }
}

bool _envelope(Map<String, Object?> record, String id, Set<String> fields) =>
    record['version'] == 1 &&
    record['id'] == id &&
    record.keys.every(fields.contains);

bool _strings(Map<String, Object?> record, List<String> fields) => fields.every(
  (field) => record[field] is String && (record[field] as String).isNotEmpty,
);

void _chapters(Object? value, String path) {
  if (value is! Map<String, Object?> || value.isEmpty) _invalid(path);
  final names = <String>{};
  for (final entry in value.entries) {
    final revision = entry.value;
    if (entry.key.length <= '.pgn'.length ||
        !entry.key.endsWith('.pgn') ||
        !_component(p.withoutExtension(entry.key)) ||
        !names.add(entry.key.toLowerCase()) ||
        revision is! Map<String, Object?> ||
        !revision.keys.every({'identity', 'digest'}.contains) ||
        !_strings(revision, ['identity', 'digest']) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(revision['digest'] as String)) {
      _invalid(path);
    }
  }
}

/// V1 allows leading dots, unlike v2's new-name UI. Historical receipts must
/// retain that compatibility; this only validates a component, never uses it.
bool _component(String value, {bool trimmed = false}) {
  final name = value.trim();
  return name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      name.length <= 120 &&
      (!trimmed || name == value) &&
      !value.endsWith(' ') &&
      !name.endsWith('.') &&
      !RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(name) &&
      !RegExp(
        r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name);
}
