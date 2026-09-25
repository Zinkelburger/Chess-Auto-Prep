import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

/// Legacy compatibility for retained native previous-journal copies. Only the
/// owning app can recover a current pending command. Its terminal history may
/// coexist with validated earlier bytes left by successful ReplaceFileW.
Future<void> checkForeignRecoveryHistory(
  Directory directory, {
  required void Function(Object? value, String id, bool terminal) validate,
}) async {
  final current = <String, Map<String, Object?>>{};
  final copies = <({String id, Map<String, Object?> value})>[];
  await for (final entry in directory.list(followLinks: false)) {
    final name = p.basename(entry.path);
    final note = _match(_noteName, name);
    final copy = _match(_copyName, name);
    if (entry is! File || (note == null && copy == null)) {
      throw const FormatException('Unknown recovery metadata entry.');
    }
    final observed = await observeFile(entry.path);
    if (observed.status != 0 || observed.bytes == null) {
      throw const FormatException('Unreadable or linked recovery metadata.');
    }
    final value = jsonDecode(utf8.decode(observed.bytes!));
    if (value is! Map<String, Object?>) {
      throw const FormatException('Malformed recovery metadata.');
    }
    final id = (note ?? copy)!.group(1)!;
    if (note != null) {
      validate(value, id, true);
      current[id] = value;
    } else {
      copies.add((id: id, value: value));
    }
  }
  for (final copy in copies) {
    validate(copy.value, copy.id, false);
    final latest = current[copy.id];
    if (latest == null || !_predecessor(copy.value, latest)) {
      throw const FormatException('Unverified native recovery copy.');
    }
  }
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
