import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'directory_entries.dart';
import 'recovery_files.dart';
import 'recovery_quarantine.dart';

/// The records in one journal folder (`Support/<name>/<id>.json`).
///
/// Only a whole record counts. A write killed before its rename leaves a
/// staged `.<id>.json.v2-tmp` beside the record it was replacing, and Windows
/// can leave the replaced bytes as `.<id>.json.v2-tmp.previous-N-N`: neither is
/// the record, so both are removed. Anything else that cannot be read or
/// [decode]d is set aside ([quarantine]) and logged, so one damaged record
/// never stops the others, or any open or save, from going ahead.
Future<List<(File, T)>> readJournal<T>(
  Directory directory, {
  required T Function(Object? value, String id) decode,
}) async {
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return const [];
  }
  final entries = await directoryEntries(directory, followLinks: false).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final records = <(File, T)>[];
  for (final entry in entries) {
    final name = p.basename(entry.path);
    if (entry is File && _leftover.hasMatch(name)) {
      log.w('remove ${entry.path}, left by a stopped journal write');
      await entry.delete();
      continue;
    }
    final id = _record.firstMatch(name)?.group(1);
    try {
      if (entry is! File || id == null) {
        throw const FormatException('not a journal record');
      }
      final value = jsonDecode(exactText(await entry.readAsBytes()));
      records.add((entry, decode(value, id)));
    } on Object catch (error) {
      await quarantine(directory.parent, entry, error);
    }
  }
  return records;
}

final _record = RegExp(r'^([A-Za-z0-9][A-Za-z0-9_-]{0,127})\.json$');
final _leftover = RegExp(r'^\..+\.v2-tmp(\.previous-[0-9]+-[0-9]+)?$');
