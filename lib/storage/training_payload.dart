import 'dart:convert';
import 'dart:typed_data';

import 'csv_records.dart';
import 'training_records.dart';
import 'training_rows.dart';
import 'recovery_files.dart';

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

  /// This change as a payload again, with every row that named a key of
  /// [moved] naming its value instead, as a chapter move repoints the rows
  /// already on disk.
  String relocated(Map<String, String> moved) {
    if (attempt case final line?) {
      final source = decodeAttempt(line)!.key.source;
      final to = moved[source];
      return jsonEncode([
        'attempt',
        to == null ? line : movedAttempt(line, source, to),
      ]);
    }
    String row(String row) {
      final cells = _cells(row);
      final to = moved[cells.first];
      return to == null ? row : encodeCsvRecord([to, ...cells.skip(1)]);
    }

    List<List<String?>> changes(List<({String? before, String after})> of) => [
      for (final change in of)
        [change.before == null ? null : row(change.before!), row(change.after)],
    ];
    return jsonEncode([
      'write',
      changes(reviews),
      changes(streaks),
      [
        for (final cells in history)
          [moved[cells.first] ?? cells.first, ...cells.skip(1)],
      ],
    ]);
  }

  Map<String, Uint8List?> plan(Map<String, Uint8List?> original) {
    final next = Map<String, Uint8List?>.of(original);
    if (reviews.isNotEmpty) {
      next[reviewsFile] = _merged(original[reviewsFile], reviewsFile, reviews);
    }
    if (streaks.isNotEmpty) {
      next[streaksFile] = _merged(original[streaksFile], streaksFile, streaks);
    }
    if (history.isNotEmpty) {
      // Appended to the bytes as they are, like the answer log: a history
      // row nobody reads back is no reason to refuse a rating.
      final was = original[historyFile];
      final rows = history.map((r) => '${encodeCsvRecord(r)}\n').join();
      next[historyFile] = was == null || _blank(was)
          ? Uint8List.fromList(
              utf8.encode(
                '${_marked(was) ? '\ufeff' : ''}$historyHeader\n$rows',
              ),
            )
          : _appended(was, rows);
    }
    if (attempt case final line?) {
      next[attemptsFile] = _appended(
        original[attemptsFile] ?? Uint8List(0),
        '$line\n',
      );
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
    jsonEncode(row.take(_keyWidth(name)).toList());

int _keyWidth(String name) => name == streaksFile ? 3 : 2;

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
  // A file emptied to blank lines, or to rows of empty cells, has no header
  // to keep; it gets one, and the empty-cell rows stay after it.
  final parsed = readCsvRecords(
    text == null || text.trim().isEmpty ? '' : text,
  );
  if (parsed is CsvUnreadable) {
    throw TrainingUnreadable(name, parsed.line, wholeFile: true);
  }
  final records = (parsed as CsvParsed).records;
  final width = headerWidth(records);
  final header = headerOf(name);
  final wanted = {
    for (final change in changes) _key(_cells(change.after), name): change,
  };
  final out = StringBuffer(
    '${marked ? '\ufeff' : ''}'
    '${records.every((r) => r.isBlank) ? '$header\n' : ''}',
  );
  for (final record in records) {
    final cells = dataCells(
      record,
      record.isBlank ? null : rowWidth(name, record, width),
    );
    final readable =
        cells != null &&
        (name == reviewsFile ? decodeReview(cells) : decodeStreak(cells)) !=
            null;
    // A row that is not one keeps its bytes; only a change to its own key
    // is refused, since it cannot say what that row held.
    if (cells != null &&
        !readable &&
        cells.length >= _keyWidth(name) &&
        wanted.containsKey(_key(cells, name))) {
      throw TrainingUnreadable(name, record.line);
    }
    final change = cells == null || !readable
        ? null
        : wanted.remove(_key(cells, name));
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
      wholeFile: true,
    );
  }
}

final class TrainingChanged implements Exception {
  const TrainingChanged(this.detail);
  final String detail;
}

/// A training file [file] is unreadable at [line]: the whole file when its
/// bytes are not text or its rows cannot be told apart ([wholeFile]),
/// otherwise the one row a change would replace.
final class TrainingUnreadable implements Exception {
  const TrainingUnreadable(this.file, this.line, {this.wholeFile = false});
  final String file;
  final int line;
  final bool wholeFile;
}

bool _marked(Uint8List? bytes) => bytes != null && hasByteOrderMark(bytes);

/// Whether [bytes] hold nothing but a byte-order mark and blank lines.
bool _blank(Uint8List bytes) => bytes
    .skip(_marked(bytes) ? 3 : 0)
    .every((b) => b == 0x20 || b == 0x09 || b == 0x0d || b == 0x0a);

/// [text] after [was]'s bytes, on a line of its own.
Uint8List _appended(Uint8List was, String text) =>
    (BytesBuilder(copy: false)
          ..add(was)
          ..add(
            utf8.encode('${was.isEmpty || was.last == 10 ? '' : '\n'}$text'),
          ))
        .takeBytes();

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
