import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/training/schedule.dart';
import '../diagnostics/log.dart';
import 'compound_commit.dart';
import 'csv_records.dart';
import 'operation_journal.dart';
import 'recovery_files.dart';
import 'training_rows.dart';

/// Captures the complete training read set while the Documents lock is held.
/// Only the moved line keys change; unrelated rows retain their original bytes.
Future<List<CompoundTraining>> lineProgressPlan(
  Directory documents, {
  required String from,
  required String to,
  required Map<String, String> ids,
  String? alternateFrom,
  String? alternateTo,
  Set<String> folded = const {},
}) async {
  final moves = <LineKey, LineKey>{
    for (final MapEntry(key: id, value: next) in ids.entries) ...{
      (source: from, id: id): (source: to, id: next),
      if (alternateFrom != null)
        (source: alternateFrom, id: id): (source: alternateTo!, id: next),
    },
  };
  final sources = {from, ?alternateFrom};
  final held = {
    for (final id in folded)
      for (final source in sources) (source: source, id: id),
  };
  return [
    for (final name in trainingParticipants)
      await _plan(documents, name, moves, sources, held),
  ];
}

Future<CompoundTraining> _plan(
  Directory root,
  String name,
  Map<LineKey, LineKey> moves,
  Set<String> sources,
  Set<LineKey> folded,
) async {
  final before = await recoveryText(p.join(root.path, name));
  if (before == null) {
    return CompoundTraining(name: name, before: null, after: null);
  }
  final after = await Isolate.run(
    () => _remap(before, name, moves, sources: sources, folded: folded).text,
  );
  return CompoundTraining(name: name, before: before, after: after);
}

/// The line keys a line move's training snapshots show moving, from each
/// row of [files] as it was planned to what it became: the rows are
/// compared in place, so only the path and line id of a row may differ.
/// Null unless that is all that changed, each moved key went to one place,
/// every row of a moved key moved, and no key moved to one that moved too:
/// then the move cannot be read back without guessing.
Map<LineKey, LineKey>? lineMovesBetween(List<CompoundTraining> files) {
  final moves = <LineKey, LineKey>{};
  final stayed = <LineKey>{};
  for (final file in files) {
    final (before, after) = (file.before, file.after);
    if (before == null || after == null) {
      if (before != after) return null;
      continue;
    }
    final rows = _rowsBetween(before, after, file.name);
    if (rows == null) return null;
    for (final (from, to) in rows) {
      if (to == null) {
        stayed.add(from);
      } else if (moves.putIfAbsent(from, () => to) != to) {
        return null;
      }
    }
  }
  if (stayed.any(moves.containsKey)) return null;
  if (moves.values.any(moves.containsKey)) return null;
  return moves;
}

/// Each row of [before] that names a line, and the line it names in
/// [after] when that changed; null when anything else differs.
List<(LineKey, LineKey?)>? _rowsBetween(
  String before,
  String after,
  String name,
) {
  final bom = before.startsWith('\ufeff');
  if (bom != after.startsWith('\ufeff')) return null;
  final was = before.substring(bom ? 1 : 0);
  final now = after.substring(bom ? 1 : 0);
  return name == attemptsFile
      ? _attemptsBetween(was, now)
      : _recordsBetween(was, now, name);
}

List<(LineKey, LineKey?)>? _attemptsBetween(String before, String after) {
  final was = before.split('\n');
  final now = after.split('\n');
  if (was.length != now.length) return null;
  final rows = <(LineKey, LineKey?)>[];
  for (var i = 0; i < was.length; i++) {
    final from = _attempt(was[i]);
    if (was[i] == now[i]) {
      if (from != null) rows.add((from.key, null));
      continue;
    }
    final to = _attempt(now[i]);
    if (from == null || to == null) return null;
    final rest = {...from.json}
      ..removeWhere((k, _) => _attemptKeys.contains(k));
    final moved = {...to.json}..removeWhere((k, _) => _attemptKeys.contains(k));
    if (jsonEncode(rest) != jsonEncode(moved)) return null;
    rows.add((from.key, to.key));
  }
  return rows;
}

const _attemptKeys = {'repertoireId', 'lineId'};

({LineKey key, Map<String, Object?> json})? _attempt(String line) {
  if (line.trim().isEmpty) return null;
  try {
    final json = jsonDecode(line);
    if (json is Map<String, Object?> &&
        json['repertoireId'] is String &&
        json['lineId'] is String) {
      return (
        key: (
          source: json['repertoireId']! as String,
          id: json['lineId']! as String,
        ),
        json: json,
      );
    }
  } on FormatException {
    // Not a row this app reads: it names no line.
  }
  return null;
}

List<(LineKey, LineKey?)>? _recordsBetween(
  String before,
  String after,
  String name,
) {
  if (readCsvRecords(before) case CsvParsed(records: final was)) {
    if (readCsvRecords(after) case CsvParsed(records: final now)) {
      if (was.length != now.length) return null;
      final width = headerWidth(was);
      final rows = <(LineKey, LineKey?)>[];
      for (var i = 0; i < was.length; i++) {
        final from = dataCells(was[i], rowWidth(name, was[i], width));
        final unchanged = was[i].source == now[i].source;
        if (unchanged && from != null && from.length >= 2) {
          rows.add(((source: from[0], id: from[1]), null));
        }
        if (unchanged) continue;
        final to = dataCells(now[i], rowWidth(name, now[i], width));
        if (from == null ||
            to == null ||
            from.length < 2 ||
            from.length != to.length ||
            was[i].terminator != now[i].terminator ||
            jsonEncode([...from.skip(2)]) != jsonEncode([...to.skip(2)])) {
          return null;
        }
        rows.add(((source: from[0], id: from[1]), (source: to[0], id: to[1])));
      }
      return rows;
    }
  }
  return null;
}

/// A line move's rows in the four training files, following its PGNs: a
/// file holding what the move planned from is written as planned, and one
/// that changed since, an answer written meanwhile, has its rows moved
/// again by the keys the record's snapshots show moving
/// ([lineMovesBetween]). Only lines that had rows when the move was planned
/// are moved again: the record keeps no other ids, so a first answer to a
/// moved line written meanwhile stays under its old key. A row it cannot
/// read, or one whose destination
/// line already has reviews or streaks, keeps its bytes and is logged.
/// A file that is not training rows, or a move the snapshots do not show,
/// is left as it is ([NotFollowed]).
final class LineRows implements Reference {
  LineRows(
    this.documents,
    this.files, {
    this.written,
    this.synchronize = syncDirectory,
  });

  /// The canonical Documents folder the four files sit in.
  final Directory documents;

  /// The record's snapshots; empty for a move without training.
  final List<CompoundTraining> files;

  /// Told once every file has followed.
  final Future<void> Function()? written;
  final Future<void> Function(String) synchronize;

  late final _moves = lineMovesBetween(files);

  // What [look] last read of each file.
  final _looked = <String, String?>{};

  String _path(String name) => p.join(documents.path, name);

  /// [HoldsAfter] once any file holds what the move wrote there: it has
  /// followed, at least in part.
  @override
  Future<Holds> look() async {
    var before = true;
    var followed = false;
    for (final file in files) {
      final String? text;
      try {
        text = await recoveryText(_path(file.name));
      } on FileSystemException catch (error) {
        return CannotTell('$error');
      } on Object catch (error) {
        return HoldsOther(describeFailure(error));
      }
      _looked[file.name] = text;
      before &= text == file.before;
      followed |= file.before != file.after && text == file.after;
    }
    if (before) return const HoldsBefore();
    if (followed) return const HoldsAfter();
    return const HoldsOther('The training rows changed since the move.');
  }

  @override
  Future<void> follow() async {
    final notFollowed = <String>[];
    for (final file in files) {
      if (await _follow(file) case final detail?) notFollowed.add(detail);
    }
    await written?.call();
    if (notFollowed.isNotEmpty) throw NotFollowed(notFollowed.join(' '));
  }

  /// Why [file] was left as it is, if it was.
  Future<String?> _follow(CompoundTraining file) async {
    final path = _path(file.name);
    final String? text;
    try {
      text = await recoveryText(path);
    } on FormatException {
      return '$path is not UTF-8 text.';
    } on RecoveryRequired catch (error) {
      return error.detail;
    }
    if (text == file.before || text == file.after) {
      await publishExactText(
        path,
        current: text,
        after: file.after,
        synchronize: synchronize,
      );
      return null;
    }
    if (text == null && _looked[file.name] != null) {
      // Here a moment ago: it is gone only for now.
      throw FileSystemException('The training file is missing for now', path);
    }
    // Removed since: it holds no rows to move.
    if (text == null) return null;
    final now = text;
    final moves = _moves;
    if (moves == null) return 'The moved lines cannot be read back for $path.';
    final String moved;
    final List<String> kept;
    try {
      (text: moved, :kept) = await Isolate.run(
        () => _remap(now, file.name, moves, again: true),
      );
    } on FormatException catch (error) {
      return '$path: ${error.message}';
    }
    for (final row in kept) {
      log.w('leave a row in $path as it is', row);
    }
    await publishText(path, moved, synchronize: synchronize);
    return null;
  }
}

/// [before], the text of the training file [name], with the rows of each
/// line [moves] names keyed at its new place. Rows of other lines keep
/// their bytes.
///
/// Planning a move ([again] false) refuses what it cannot carry: a folded
/// line with rows, a row it cannot read that may be one of the moved
/// lines', a destination line that has rows already. Moving rows again
/// after the move was recorded keeps such a row's bytes instead, named in
/// `kept`; there the attempts log and the review history, which hold many
/// rows per line, never collide.
({String text, List<String> kept}) _remap(
  String before,
  String name,
  Map<LineKey, LineKey> moves, {
  Set<String>? sources,
  Set<LineKey> folded = const {},
  bool again = false,
}) {
  final from = sources ?? {for (final key in moves.keys) key.source};
  final targets = moves.values.toSet();
  final kept = <String>[];
  final prefix = before.startsWith('\ufeff') ? '\ufeff' : '';
  final body = before.substring(prefix.length);
  if (body.trim().isEmpty) return (text: before, kept: kept);
  // The destination lines with rows already, which a row moved again
  // would collide with; the logs hold many rows per line.
  final collides = again && name != attemptsFile && name != historyFile;
  final present = <LineKey>{};

  LineKey? moved(LineKey key) {
    if (!again && targets.contains(key)) {
      throw FormatException(
        'Training already exists for the destination line in $name.',
      );
    }
    if (folded.contains(key)) {
      throw const FormatException(
        'This line has training history. Move it onto the chapter as a separate line to preserve its progress.',
      );
    }
    final target = moves[key];
    if (target == null || !present.contains(target)) return target;
    kept.add('${key.source} ${key.id}: ${target.source} ${target.id} has rows');
    return null;
  }

  // A record this code cannot read keeps its bytes, unless it may be one of
  // the moved line's: then planning refuses rather than leave it behind.
  String unread(String raw) {
    if (from.any((path) => mayName(raw, path))) {
      if (!again) throw FormatException('Malformed $name.');
      kept.add(raw);
    }
    return raw;
  }

  final String after;
  if (name == attemptsFile) {
    after = body
        .split('\n')
        .map((line) {
          if (line.trim().isEmpty) return line;
          final attempt = _attempt(line);
          if (attempt == null) return unread(line);
          final target = moved(attempt.key);
          return target == null
              ? line
              : jsonEncode({
                  ...attempt.json,
                  'repertoireId': target.source,
                  'lineId': target.id,
                });
        })
        .join('\n');
  } else {
    final parsed = readCsvRecords(body);
    if (parsed is! CsvParsed) throw FormatException('Malformed $name.');
    final width = headerWidth(parsed.records);
    if (width == null) throw FormatException('Missing header in $name.');
    List<String>? cells(CsvRecord record) =>
        dataCells(record, rowWidth(name, record, width));
    for (final record in parsed.records.where((_) => collides)) {
      final row = cells(record);
      if (row != null && row.length >= 2 && isWholeRow(name, row, width)) {
        present.add((source: row[0], id: row[1]));
      }
    }
    final out = StringBuffer();
    for (final record in parsed.records) {
      final row = cells(record);
      var text = record.source;
      if (row != null) {
        if (row.length < 2 || !isWholeRow(name, row, width)) {
          unread(text);
        } else if (moved((source: row[0], id: row[1])) case final target?) {
          text = encodeCsvRecord([target.source, target.id, ...row.skip(2)]);
        }
      }
      out
        ..write(text)
        ..write(record.terminator);
    }
    after = out.toString();
  }
  return (text: '$prefix$after', kept: kept);
}
