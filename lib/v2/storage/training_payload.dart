import 'dart:convert';
import 'dart:typed_data';

import 'csv_records.dart';
import 'training_rows.dart';

const trainingFileNames = [reviewsFile, streaksFile, historyFile, attemptsFile];

/// Frozen row changes prepared from the accepted projection. File snapshots
/// are derived only when this command reaches the head of the durable queue.
final class TrainingPayload {
  TrainingPayload._(this.reviews, this.streaks, this.history, this.attempt);
  final List<({String? before, String after})> reviews;
  final List<({String? before, String after})> streaks;
  final List<List<String>> history;
  final String? attempt;

  factory TrainingPayload.decode(String payload) {
    final value = jsonDecode(payload);
    _safeStrings(value);
    if (value is! List<Object?>) {
      throw const FormatException('Training payload');
    }
    if (value.length == 2 && value[0] == 'attempt' && value[1] is String) {
      final line = value[1]! as String;
      _safeStrings(jsonDecode(line));
      final decoded = decodeAttempt(line);
      if (decoded == null ||
          encodeAttempt(decoded) != line ||
          decoded.ply < 0 ||
          decoded.key.id.isEmpty ||
          line.contains('\n') ||
          line.contains('\r') ||
          decodeAttempt(line) == null) {
        throw const FormatException('Training answer');
      }
      return TrainingPayload._(const [], const [], const [], line);
    }
    if (value.length != 4 ||
        value[0] != 'write' ||
        value[3] is! List<Object?>) {
      throw const FormatException('Training write');
    }
    final history = <List<String>>[];
    for (final row in value[3]! as List<Object?>) {
      if (row is! List<Object?> ||
          row.length != 6 ||
          row.any((cell) => cell is! String)) {
        throw const FormatException('Training history');
      }
      final cells = row.cast<String>();
      if (cells[1].isEmpty ||
          DateTime.tryParse(cells[2]) == null ||
          !const {'0', '1'}.contains(cells[4]) ||
          !const {'trainer', 'marked'}.contains(cells[5])) {
        throw const FormatException('Training history values');
      }
      history.add(List.unmodifiable(cells));
    }
    return TrainingPayload._(
      _changes(value[1], reviewsFile),
      _changes(value[2], streaksFile),
      List.unmodifiable(history),
      null,
    );
  }

  Set<String> get sources => {
    for (final change in [...reviews, ...streaks]) _cells(change.after).first,
    for (final row in history) row.first,
    if (attempt != null) decodeAttempt(attempt!)!.key.source,
  };

  Map<String, Uint8List?> plan(Map<String, Uint8List?> original) {
    final next = Map<String, Uint8List?>.of(original);
    if (reviews.isNotEmpty) {
      next[reviewsFile] = _merged(original[reviewsFile], reviewsFile, reviews);
    }
    if (streaks.isNotEmpty) {
      next[streaksFile] = _merged(original[streaksFile], streaksFile, streaks);
    }
    if (history.isNotEmpty) {
      final text = _text(historyFile, original[historyFile]);
      final was = text == null || text.trim().isEmpty
          ? '$historyHeader\n'
          : text.endsWith('\n')
          ? text
          : '$text\n';
      next[historyFile] = Uint8List.fromList(
        utf8.encode(
          '${_marked(original[historyFile]) ? '\ufeff' : ''}$was${history.map((r) => '${encodeCsvRecord(r)}\n').join()}',
        ),
      );
    }
    if (attempt case final line?) {
      final was = original[attemptsFile] ?? Uint8List(0);
      next[attemptsFile] =
          (BytesBuilder(copy: false)
                ..add(was)
                ..add(
                  utf8.encode(
                    '${was.isEmpty || was.last == 10 ? '' : '\n'}$line\n',
                  ),
                ))
              .takeBytes();
    }
    return next;
  }
}

List<({String? before, String after})> _changes(Object? value, String name) {
  if (value is! List<Object?>) throw const FormatException('Training changes');
  final result = <({String? before, String after})>[];
  final keys = <String>{};
  for (final change in value) {
    if (change is! List<Object?> ||
        change.length != 2 ||
        (change[0] != null && change[0] is! String) ||
        change[1] is! String) {
      throw const FormatException('Training change');
    }
    final before = change[0] as String?;
    final after = change[1]! as String;
    final key = _key(_validCells(after, name), name);
    if (!keys.add(key) ||
        (before != null && _key(_validCells(before, name), name) != key)) {
      throw const FormatException('Duplicate or mismatched training change');
    }
    result.add((before: before, after: after));
  }
  return List.unmodifiable(result);
}

List<String> _cells(String row) {
  final parsed = readCsvRecords(row);
  if (parsed is! CsvParsed || parsed.records.length != 1) {
    throw const FormatException('Training row');
  }
  return parsed.records.single.fields;
}

List<String> _validCells(String row, String name) {
  final cells = _cells(row);
  if (cells.length != (name == reviewsFile ? 11 : 5) ||
      (name == reviewsFile ? decodeReview(cells) : decodeStreak(cells)) ==
          null) {
    throw const FormatException('Invalid training row');
  }
  if (_canonical(cells, name) != row) {
    throw const FormatException('Noncanonical training row');
  }
  return cells;
}

String _key(List<String> row, String name) =>
    jsonEncode(row.take(name == streaksFile ? 3 : 2).toList());

String _canonical(List<String> cells, String name) => encodeCsvRecord(
  name == reviewsFile
      ? encodeReview(decodeReview(cells)!)
      : encodeStreak(decodeStreak(cells)!),
);

Uint8List _merged(
  Uint8List? bytes,
  String name,
  List<({String? before, String after})> changes,
) {
  final text = _text(name, bytes);
  final marked = _marked(bytes);
  final parsed = readCsvRecords(text ?? '');
  if (parsed is CsvUnreadable) throw TrainingUnreadable(name, parsed.line);
  final records = (parsed as CsvParsed).records;
  final width = headerWidth(records);
  final header = headerOf(name);
  final wanted = {
    for (final change in changes) _key(_cells(change.after), name): change,
  };
  final out = StringBuffer(
    '${marked ? '\ufeff' : ''}${records.isEmpty ? '$header\n' : ''}',
  );
  for (final record in records) {
    final cells = dataCells(
      record,
      record.isBlank ? null : rowWidth(name, record, width),
    );
    if (cells != null &&
        (name == reviewsFile ? decodeReview(cells) : decodeStreak(cells)) ==
            null) {
      throw TrainingUnreadable(name, record.line);
    }
    final change = cells == null ? null : wanted.remove(_key(cells, name));
    String replacement;
    if (cells == null) {
      replacement = record.isBlank ? record.source : header;
    } else if (change == null) {
      replacement = record.source;
    } else {
      final current = _canonical(cells, name);
      if (current != change.after && current != change.before) {
        throw TrainingChanged(name);
      }
      replacement = change.after;
    }
    out
      ..write(replacement)
      ..write(record.terminator);
  }
  for (final change in wanted.values) {
    if (change.before != null) throw TrainingChanged(name);
    if (out.isNotEmpty && !out.toString().endsWith('\n')) out.write('\n');
    out.writeln(change.after);
  }
  return Uint8List.fromList(utf8.encode(out.toString()));
}

String? _text(String name, Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException catch (error) {
    final end = error.offset?.clamp(0, bytes.length) ?? 0;
    throw TrainingUnreadable(
      name,
      1 + bytes.take(end).where((b) => b == 10).length,
    );
  }
}

final class TrainingChanged implements Exception {
  const TrainingChanged(this.detail);
  final String detail;
}

final class TrainingUnreadable implements Exception {
  const TrainingUnreadable(this.file, this.line);
  final String file;
  final int line;
}

bool _marked(Uint8List? bytes) =>
    bytes != null &&
    bytes.length >= 3 &&
    bytes[0] == 0xef &&
    bytes[1] == 0xbb &&
    bytes[2] == 0xbf;

void _safeStrings(Object? value) {
  if (value is String) {
    if (value.contains('\u0000') || utf8.decode(utf8.encode(value)) != value) {
      throw const FormatException('Invalid training text');
    }
  } else if (value is List<Object?>) {
    for (final item in value) {
      _safeStrings(item);
    }
  } else if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      _safeStrings(entry.key);
      _safeStrings(entry.value);
    }
  }
}
