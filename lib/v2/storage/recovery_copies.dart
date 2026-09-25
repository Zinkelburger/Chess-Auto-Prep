import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'relocation_notes.dart' show RecoveryRequired;

/// ReplaceFileW may finish publishing a journal and leave its previous bytes
/// beside it, including after a crash before cleanup. Such copies are retained
/// evidence, never recovery commands. Admit only a fully validated predecessor
/// of the same immutable manifest; a missing current record proves nothing.
Future<List<T>> readRecoveryRecords<T>(
  Directory directory, {
  required T Function(Object? value, String id) decode,
  bool Function(Map<String, Object?> previous, Map<String, Object?> current)?
  predecessor,
}) async {
  final current = <String, Map<String, Object?>>{};
  final copies = <({String id, Map<String, Object?> value})>[];
  final records = <T>[];
  await for (final (id, isCurrent, value) in _metadata(directory)) {
    if (isCurrent) {
      records.add(decode(value, id));
      current[id] = value;
    } else {
      copies.add((id: id, value: value));
    }
  }
  for (final copy in copies) {
    decode(copy.value, copy.id);
    final latest = current[copy.id];
    if (latest == null || !(predecessor ?? _predecessor)(copy.value, latest)) {
      throw RecoveryRequired('Unverified native recovery copy for ${copy.id}.');
    }
  }
  return records;
}

/// Batch native reads within one worker without trusting a cached directory or
/// receipt. The byte budget keeps large pending manifests out of a large batch.
Stream<(String, bool, Map<String, Object?>)> _metadata(
  Directory directory,
) async* {
  final entries = await directoryEntries(directory, followLinks: false).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  var offset = 0;
  while (offset < entries.length) {
    final batch = entries.skip(offset).take(32).toList();
    final names = [for (final entry in batch) _identity(entry)];
    final observations = await observeFileBatch([
      for (final entry in batch) entry.path,
    ]);
    for (var index = 0; index < observations.length; index++) {
      final observed = observations[index];
      final path = batch[index].path;
      final bytes = observed.bytes;
      if (observed.status != 0 || bytes == null) {
        throw RecoveryRequired(
          'Recovery metadata is unreadable or linked: $path.',
        );
      }
      final marked =
          bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf;
      final text = utf8.decode(bytes);
      final value = jsonDecode(marked ? '\ufeff$text' : text);
      if (value is! Map<String, Object?>) {
        throw RecoveryRequired('Malformed recovery metadata at $path.');
      }
      yield (names[index].$1, names[index].$2, value);
    }
    offset += observations.length;
  }
}

(String, bool) _identity(FileSystemEntity entry) {
  final name = p.basename(entry.path);
  final note = _match(_noteName, name);
  final copy = _match(_copyName, name);
  if (entry is! File || (note == null && copy == null)) {
    throw RecoveryRequired('Unsupported recovery metadata at ${entry.path}.');
  }
  return ((note ?? copy)!.group(1)!, note != null);
}

RegExpMatch? _match(RegExp pattern, String value) {
  final match = pattern.firstMatch(value);
  return match?.group(0) == value ? match : null;
}

bool _predecessor(Map<String, Object?> previous, Map<String, Object?> current) {
  final allowed = switch (previous['state']) {
    'prepared' ||
    'cancelled' => const {'prepared', 'committing', 'complete', 'cancelled'},
    'committing' => const {'committing', 'complete'},
    'complete' => const {'complete'},
    _ => const <String>{},
  };
  if (!allowed.contains(current['state'])) return false;
  final before = Map<String, Object?>.of(previous)..remove('state');
  final after = Map<String, Object?>.of(current)..remove('state');
  return const DeepCollectionEquality().equals(before, after);
}

final _noteName = RegExp(r'^([A-Za-z0-9][A-Za-z0-9_-]{0,127})\.json$');
final _copyName = RegExp(
  r'^\.([A-Za-z0-9][A-Za-z0-9_-]{0,127})\.json\.v2-tmp\.previous-([1-9][0-9]*)-([1-9][0-9]*)$',
);
