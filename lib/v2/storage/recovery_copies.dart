import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'recovery_files.dart';
import 'relocation_notes.dart' show RecoveryRequired;

/// ReplaceFileW may finish publishing a journal and leave its previous bytes
/// beside it, including after a crash before cleanup. Such copies are retained
/// evidence, never recovery commands. Admit only a fully validated predecessor
/// of the same immutable manifest; a missing current record proves nothing.
Future<List<T>> readRecoveryRecords<T>(
  Directory directory, {
  required T Function(Object? value, String id) decode,
}) async {
  final entries = await directoryEntries(directory, followLinks: false).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final current = <String, Map<String, Object?>>{};
  final copies = <({String id, Map<String, Object?> value})>[];
  final records = <T>[];
  for (final entry in entries) {
    final name = p.basename(entry.path);
    final note = _match(_noteName, name);
    final copy = _match(_copyName, name);
    if (entry is! File || (note == null && copy == null)) {
      throw RecoveryRequired('Unsupported recovery metadata at ${entry.path}.');
    }
    final text = await recoveryText(entry.path);
    if (text == null) {
      throw RecoveryRequired('Recovery metadata disappeared: ${entry.path}.');
    }
    final value = jsonDecode(text);
    if (value is! Map<String, Object?>) {
      throw RecoveryRequired('Malformed recovery metadata at ${entry.path}.');
    }
    final id = (note ?? copy)!.group(1)!;
    if (note != null) {
      records.add(decode(value, id));
      current[id] = value;
    } else {
      copies.add((id: id, value: value));
    }
  }
  for (final copy in copies) {
    decode(copy.value, copy.id);
    final latest = current[copy.id];
    if (latest == null || !_predecessor(copy.value, latest)) {
      throw RecoveryRequired('Unverified native recovery copy for ${copy.id}.');
    }
  }
  return records;
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
