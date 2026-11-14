import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'directory_entries.dart';
import 'operation_id.dart';
import 'recovery_files.dart';
import 'recovery_quarantine.dart';

/// What one look at a journal folder found: the records it could read,
/// those it could not read just now, and the name of every record it met
/// ([recordName]), whatever came of it.
typedef JournalRead<T> = ({
  List<(File, T)> records,
  List<(File, String id, FileSystemException error)> unread,
  Set<String> found,
});

/// The records in one journal folder (`Support/<name>/<id>.json`).
///
/// Only a whole record counts. A write killed before its rename leaves a
/// staged `.<id>.json.v2-tmp` beside the record it was replacing, and Windows
/// can leave the replaced bytes as `.<id>.json.v2-tmp.previous-N-N`: neither is
/// the record, so both are removed. A record's `<id>.following` and
/// `<id>.aside` markers ([followingMarker], [asideMarker]) stay beside it and
/// go wherever it goes; one whose record is gone is removed. A record whose
/// read failed for now (held open, changing while read, briefly missing) is
/// [unread] and left where it is for the next look. Anything else that cannot be read
/// or [decode]d is set aside ([quarantine]) and logged, so one damaged record
/// never stops the others, or any open or save, from going ahead.
Future<JournalRead<T>> readJournalEntries<T>(
  Directory directory, {
  required T Function(Object? value, String id) decode,
}) async {
  final records = <(File, T)>[];
  final unread = <(File, String, FileSystemException)>[];
  final found = <String>{};
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return (records: records, unread: unread, found: found);
  }
  final entries = await directoryEntries(directory, followLinks: false).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final names = {for (final entry in entries) p.basename(entry.path)};
  for (final entry in entries) {
    final name = p.basename(entry.path);
    found.add(recordName(name));
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
      final List<int> bytes;
      try {
        bytes = await entry.readAsBytes();
      } on FileSystemException catch (error) {
        if (_denied(error)) rethrow;
        log.w('read ${entry.path} later', error);
        unread.add((entry, id, error));
        continue;
      }
      records.add((entry, decode(jsonDecode(utf8.decode(bytes)), id)));
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
  return (records: records, unread: unread, found: found);
}

/// Whether [error] refuses this app the record for good: its permissions,
/// not a passing failure such as a file held open (on Windows, a sharing or
/// lock violation, which dart:io also reports as denied access).
bool _denied(FileSystemException error) {
  final code = error.osError?.errorCode;
  return Platform.isWindows ? code == 5 : code == 1 || code == 13;
}

/// The records [readJournalEntries] could read now; see there.
Future<List<(File, T)>> readJournal<T>(
  Directory directory, {
  required T Function(Object? value, String id) decode,
}) async => (await readJournalEntries(directory, decode: decode)).records;

/// The record a journal folder entry named [name] belongs to: a record's
/// markers name the record, anything else names itself.
String recordName(String name) => _names.contains(p.extension(name))
    ? p.basenameWithoutExtension(name)
    : name;

const _names = {'.json', _marker, _aside};

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

/// Removes the record of an operation that is done, then its marker, and
/// flushes its folder. It deletes without asking first: a look that wrongly
/// answers "missing" would leave a finished record behind, pending forever.
Future<void> forgetRecord(
  File record, {
  Future<void> Function(String) synchronize = syncDirectory,
}) async {
  for (final file in [record, followingMarker(record)]) {
    try {
      await _remove(file);
    } on PathNotFoundException {
      // Already gone.
    }
  }
  await flushRecoveryDirectory(record.parent.path, synchronize: synchronize);
}

Future<void> _remove(File file) => file.delete();

final _leftover = RegExp(r'^\..+\.v2-tmp(\.previous-[0-9]+-[0-9]+)?$');
