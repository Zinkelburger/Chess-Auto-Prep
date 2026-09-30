import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:document_file_io/document_file_io.dart';

import '../diagnostics/log.dart';
import 'directory_entries.dart';
import 'operation_id.dart';
import 'recovery_files.dart';
import 'recovery_quarantine.dart';

/// The records in one journal folder (`Support/<name>/<id>.json`).
///
/// Only a whole record counts. A write killed before its rename leaves a
/// staged `.<id>.json.v2-tmp` beside the record it was replacing, and Windows
/// can leave the replaced bytes as `.<id>.json.v2-tmp.previous-N-N`: neither is
/// the record, so both are removed. A record's `<id>.following` and
/// `<id>.aside` markers ([followingMarker], [asideMarker]) stay beside it and
/// go wherever it goes; one whose record is gone is removed. Anything else
/// that cannot be read or [decode]d is set aside ([quarantine]) and logged,
/// so one damaged record never stops the others, or any open or save, from
/// going ahead.
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
  final names = {for (final entry in entries) p.basename(entry.path)};
  final records = <(File, T)>[];
  for (final entry in entries) {
    final name = p.basename(entry.path);
    final marker = entry is File && _markers.contains(p.extension(name));
    if (marker && names.contains(p.setExtension(name, '.json'))) continue;
    if (marker || (entry is File && _leftover.hasMatch(name))) {
      log.w('remove ${entry.path}, left by a stopped journal write');
      await _remove(entry);
      continue;
    }
    try {
      if (entry is! File || p.extension(name) != '.json') {
        throw const FormatException('not a journal record');
      }
      final id = OperationId(p.basenameWithoutExtension(name));
      final value = jsonDecode(utf8.decode(await entry.readAsBytes()));
      records.add((entry, decode(value, id)));
    } on Object catch (error) {
      await quarantine(directory.parent, entry, error);
      for (final extension in _markers) {
        final marker = p.setExtension(name, extension);
        if (names.contains(marker) && marker != name) {
          await quarantine(
            directory.parent,
            File(p.join(directory.path, marker)),
            error,
          );
        }
      }
    }
  }
  return records;
}

const _marker = '.following';
const _aside = '.aside';
const _markers = {_marker, _aside};

/// The marker saying [record]'s operation stopped guarding with only its
/// references left to follow: a later finish follows them without looking
/// at its pivots, which the user may have saved over since. Only
/// `<id>.json` names are records, so a build without markers sets it aside
/// and finishes the record by its own rules.
File followingMarker(File record) => File(p.setExtension(record.path, _marker));

/// The marker saying [record]'s operation was set aside: it is never carried
/// out again, only moved into quarantine, which may not have worked the
/// first time. It is written once what the operation undoes is put back and
/// before the record moves, so a record the disk would not let go of never
/// applies again what was undone. Journal folders are the new app's alone,
/// so no older reader has to know it.
File asideMarker(File record) => File(p.setExtension(record.path, _aside));

/// Sets [entry] aside ([quarantine]) with its following marker, if it has
/// one; false when [entry] itself could not be moved. Its aside marker only
/// said it was to be moved, so it goes once it has been.
Future<bool> quarantineRecord(
  Directory support,
  FileSystemEntity entry,
  Object reason,
) async {
  if (!await quarantine(support, entry, reason)) return false;
  if (entry is! File) return true;
  final marker = followingMarker(entry);
  if (await marker.exists()) await quarantine(support, marker, reason);
  final aside = asideMarker(entry);
  try {
    if (await aside.exists()) await _remove(aside);
  } on FileSystemException catch (error) {
    // The next readJournal removes a marker without its record.
    log.w('remove ${aside.path}', error);
  }
  return true;
}

/// Removes the record of an operation that is done, which is on disk, then
/// its marker, and flushes its folder.
Future<void> forgetRecord(
  File record, {
  Future<void> Function(String) synchronize = syncDirectory,
}) async {
  for (final file in [record, followingMarker(record)]) {
    if (await file.exists()) await _remove(file);
  }
  await flushRecoveryDirectory(record.parent.path, synchronize: synchronize);
}

Future<void> _remove(File file) => file.delete();

final _leftover = RegExp(r'^\..+\.v2-tmp(\.previous-[0-9]+-[0-9]+)?$');
