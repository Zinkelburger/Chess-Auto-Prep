import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'compound_commit.dart';
import 'csv_records.dart';
import 'recovery_files.dart';
import 'training_rows.dart';

const trainingParticipants = {
  reviewsFile,
  streaksFile,
  historyFile,
  attemptsFile,
};

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
}) async => [
  for (final name in trainingParticipants)
    await _plan(
      documents,
      name,
      from,
      to,
      ids,
      alternateFrom,
      alternateTo,
      folded,
    ),
];

Future<CompoundTraining> _plan(
  Directory root,
  String name,
  String from,
  String to,
  Map<String, String> ids,
  String? aliasFrom,
  String? aliasTo,
  Set<String> folded,
) async {
  final before = await recoveryText(p.join(root.path, name));
  if (before == null) {
    return CompoundTraining(name: name, before: null, after: null);
  }
  final after = await Isolate.run(
    () => _remap(before, name, from, to, ids, aliasFrom, aliasTo, folded),
  );
  return CompoundTraining(name: name, before: before, after: after);
}

String _remap(
  String before,
  String name,
  String from,
  String to,
  Map<String, String> ids,
  String? aliasFrom,
  String? aliasTo,
  Set<String> folded,
) {
  final destinationIds = ids.values.toSet();
  (String, String)? moved(String path, String id) {
    if ((path == from || path == aliasFrom) && folded.contains(id)) {
      throw const FormatException(
        'This line has training history. Move it onto the chapter as a separate line to preserve its progress.',
      );
    }
    final next = ids[id];
    if (next == null) return null;
    if (path == from) return (to, next);
    if (aliasFrom != null && path == aliasFrom) return (aliasTo!, next);
    return null;
  }

  void collision(String path, String id) {
    if ((path == to || path == aliasTo) && destinationIds.contains(id)) {
      throw FormatException(
        'Training already exists for the destination line in $name.',
      );
    }
  }

  final prefix = before.startsWith('\ufeff') ? '\ufeff' : '';
  final body = before.substring(prefix.length);
  if (body.trim().isEmpty) {
    return before;
  }
  final String after;
  if (name == attemptsFile) {
    after = body
        .split('\n')
        .map((line) {
          if (line.trim().isEmpty) return line;
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, Object?> ||
              decoded['repertoireId'] is! String ||
              decoded['lineId'] is! String) {
            throw const FormatException('Malformed training attempt.');
          }
          final path = decoded['repertoireId'] as String;
          final id = decoded['lineId'] as String;
          collision(path, id);
          final target = moved(path, id);
          return target == null
              ? line
              : jsonEncode({
                  ...decoded,
                  'repertoireId': target.$1,
                  'lineId': target.$2,
                });
        })
        .join('\n');
  } else {
    final parsed = readCsvRecords(body);
    if (parsed is! CsvParsed) throw FormatException('Malformed $name.');
    final width = headerWidth(parsed.records);
    if (width == null) throw FormatException('Missing header in $name.');
    final out = StringBuffer();
    for (final record in parsed.records) {
      final cells = dataCells(record, rowWidth(name, record, width));
      var text = record.source;
      if (cells != null) {
        if (cells.length < 2 || !isWholeRow(name, cells, width)) {
          throw FormatException('Malformed $name.');
        }
        collision(cells[0], cells[1]);
        final target = moved(cells[0], cells[1]);
        if (target != null) {
          text = encodeCsvRecord([target.$1, target.$2, ...cells.skip(2)]);
        }
      }
      out
        ..write(text)
        ..write(record.terminator);
    }
    after = out.toString();
  }
  return '$prefix$after';
}
