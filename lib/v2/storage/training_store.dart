/// Reading and writing training progress: the review schedule, the move
/// streaks, the rating history and the log of answers, in the Documents
/// folder the old app keeps them in.
///
/// Both apps write these files, so a write is optimistic. It says what each
/// row it changes held when it was read (`before`) and what it holds now
/// (`after`); under the Documents lock — the one the old app takes for the
/// same files — a row that holds neither was changed by somebody else, and
/// the whole write is refused rather than put over their answer. Only the
/// rows a write names are touched; every other record keeps its bytes.
///
/// Every file is read and checked before any is written. The first write to
/// a file keeps a `<file>.pre-csv-v2.bak` copy of it, as the old app does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/training/records.dart';
import '../chess/training/schedule.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'csv_records.dart';
import 'file_lock.dart';
import 'training_rows.dart';

/// A row as read and as it is to be written; `before` is null for a row the
/// file did not have.
typedef Change<T> = ({T? before, T after});

/// Where one move's streak lives: its line and its ply.
typedef StreakKey = ({LineKey line, int ply});

/// The training files. The filesystem is a real boundary, so this is an
/// interface: [TrainingStore] in the app, a scripted one in tests.
abstract interface class ProgressFiles {
  /// Everything recorded for the chapters at [sources].
  Future<ProgressRead> read(Set<String> sources);

  /// Writes a line's outcome, or a change to the schedule by hand: the
  /// [reviews] and [streaks] rows it changes and the [history] it adds.
  Future<ProgressWrite> write({
    List<Change<Review>> reviews,
    List<Change<MoveStreak>> streaks,
    List<HistoryRow> history,
  });

  /// Adds one answer to the log, as it is given.
  Future<ProgressWrite> logAttempt(Attempt attempt);
}

final class TrainingStore implements ProgressFiles {
  TrainingStore(this.documents);

  /// The folder the four files sit in, beside `repertoires/`.
  final Directory documents;

  /// The wrong answers of the whole log as last read, with the size and
  /// time the file had then. The log only grows, and every chapter opened
  /// reads it, so it is read again only when the file changed.
  ({int size, DateTime modified, List<Attempt> wrong})? _log;

  @override
  Future<ProgressRead> read(Set<String> sources) async {
    try {
      final reviews = await _rows(_reviewCodec);
      final streaks = await _rows(_streakCodec);
      // A key written twice is read as its first row, the one a write
      // replaces.
      final byLine = <LineKey, Review>{};
      for (final r in reviews) {
        if (sources.contains(r.key.source)) byLine.putIfAbsent(r.key, () => r);
      }
      final byMove = <StreakKey, MoveStreak>{};
      for (final s in streaks) {
        if (!sources.contains(s.key.source)) continue;
        byMove.putIfAbsent((line: s.key, ply: s.ply), () => s);
      }
      return ProgressLoaded(
        reviews: byLine,
        streaks: byMove,
        mistakes: await _mistakes(sources),
      );
    } on _Unreadable catch (unreadable) {
      return unreadable.result;
    } on FileSystemException catch (error) {
      log.e('read the training progress in ${documents.path}', error);
      return ProgressFailed(_detail(error));
    }
  }

  @override
  Future<ProgressWrite> write({
    List<Change<Review>> reviews = const [],
    List<Change<MoveStreak>> streaks = const [],
    List<HistoryRow> history = const [],
  }) => _locked('write the training progress', () async {
    final planned = <_Planned>[
      if (reviews.isNotEmpty) await _merged(reviews, _reviewCodec),
      if (streaks.isNotEmpty) await _merged(streaks, _streakCodec),
      if (history.isNotEmpty)
        await _appended(historyFile, [
          for (final row in history) encodeCsvRecord(encodeHistory(row)),
        ]),
    ];
    await removeStaleTemporaries(documents);
    for (final file in planned) {
      await _keepFirstVersion(file);
    }
    for (final file in planned) {
      await replaceFile(_path(file.name), utf8.encode(file.text));
    }
    return const ProgressWritten();
  });

  /// The file is replaced whole rather than appended to in place: an
  /// append cut short leaves half a line, which the old app will not read
  /// past.
  @override
  Future<ProgressWrite> logAttempt(Attempt attempt) =>
      _locked('log an answer', () async {
        final file = File(_path(attemptsFile));
        final was = await file.exists() ? await file.readAsString() : '';
        final gap = was.isEmpty || was.endsWith('\n') ? '' : '\n';
        await replaceFile(
          file.path,
          utf8.encode('$was$gap${encodeAttempt(attempt)}\n'),
        );
        return const ProgressWritten();
      });

  Future<ProgressWrite> _locked(
    String action,
    Future<ProgressWrite> Function() write,
  ) async {
    try {
      return await withDirectoryLock(documents, write);
    } on _Unreadable catch (unreadable) {
      return unreadable.result;
    } on _Changed catch (changed) {
      log.w('$action in ${documents.path}', 'row changed: ${changed.row}');
      return const ProgressConflict();
    } on Object catch (error) {
      log.e('$action in ${documents.path}', error);
      return ProgressFailed(_detail(error));
    }
  }

  String _path(String name) => p.join(documents.path, name);

  Future<String?> _text(String name) async {
    final file = File(_path(name));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } on FormatException {
      throw _Unreadable(name, 1);
    }
  }

  Future<List<CsvRecord>> _records(String name, String? text) async {
    if (text == null || text.trim().isEmpty) return const [];
    return switch (readCsvRecords(text)) {
      CsvParsed(:final records) => records,
      CsvUnreadable(:final line) => throw _Unreadable(name, line),
    };
  }

  /// Every row of the CSV [name]; a row that is not one makes the whole file
  /// unreadable rather than silently missing.
  Future<List<T>> _rows<T, K>(_Codec<T, K> codec) async {
    final name = codec.file;
    final records = await _records(name, await _text(name));
    final header = headerWidth(records);
    return [
      for (final record in records)
        if (codec.cells(record, header) case final cells?)
          codec.decode(cells) ?? (throw _Unreadable(name, record.line)),
    ];
  }

  /// The wrong answers given in [sources], oldest first. A line the log
  /// cannot read is passed over: the log is the old app's too, and one torn
  /// line must not hide the rest.
  Future<List<Attempt>> _mistakes(Set<String> sources) async {
    final wrong = await _wrongAnswers();
    return [
      for (final a in wrong)
        if (sources.contains(a.key.source)) a,
    ];
  }

  Future<List<Attempt>> _wrongAnswers() async {
    final file = File(_path(attemptsFile));
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) return const [];
    final log = _log;
    if (log != null && log.size == stat.size && log.modified == stat.modified) {
      return log.wrong;
    }
    // Stamped with the size and time from before the read: a write in
    // between makes the next read look again rather than miss it.
    final wrong = [
      for (final line in const LineSplitter().convert(
        await _text(attemptsFile) ?? '',
      ))
        if (decodeAttempt(line) case final a? when !a.correct) a,
    ];
    _log = (size: stat.size, modified: stat.modified, wrong: wrong);
    return wrong;
  }

  /// The file [codec] reads with each of [changes] in place of the row it
  /// names, or added at the end when the file has no such row.
  ///
  /// Rows are written in the current width, so an older header is written
  /// as the current one, as the old app writes it: a chapter move reads the
  /// rows by the header's width, and 11 columns under an 8-column header
  /// would be read as a path with a comma in it.
  Future<_Planned> _merged<T, K>(
    List<Change<T>> changes,
    _Codec<T, K> codec,
  ) async {
    final name = codec.file;
    final header = headerOf(name);
    final original = await _text(name);
    final records = await _records(name, original);
    final width = headerWidth(records);
    final wanted = {for (final c in changes) codec.key(c.after): c};
    final out = StringBuffer(records.isEmpty ? '$header\n' : '');
    for (final record in records) {
      final cells = codec.cells(record, width);
      final row = cells == null ? null : codec.decode(cells);
      if (cells != null && row == null) throw _Unreadable(name, record.line);
      final change = row == null ? null : wanted.remove(codec.key(row));
      final text = cells == null
          ? (record.isBlank ? record.source : header)
          : change == null
          ? record.source
          : _replaced(row, change, codec);
      out
        ..write(text)
        ..write(record.terminator);
    }
    for (final change in wanted.values) {
      if (change.before != null) throw _Changed(codec.row(change.before as T));
      if (out.isNotEmpty && !out.toString().endsWith('\n')) out.write('\n');
      out.writeln(codec.row(change.after));
    }
    return _Planned(name, original, out.toString());
  }

  String _replaced<T, K>(T? current, Change<T> change, _Codec<T, K> codec) {
    final now = codec.row(current as T);
    final after = codec.row(change.after);
    final before = change.before;
    if (now != after && (before == null || now != codec.row(before))) {
      throw _Changed(now);
    }
    return after;
  }

  Future<_Planned> _appended(String name, List<String> rows) async {
    final header = headerOf(name);
    final original = await _text(name);
    final was = original == null || original.trim().isEmpty
        ? '$header\n'
        : original.endsWith('\n')
        ? original
        : '$original\n';
    return _Planned(name, original, '$was${rows.map((r) => '$r\n').join()}');
  }

  /// The old app keeps the bytes a file held before its first write in its
  /// current format; a file that has that copy already is left alone.
  Future<void> _keepFirstVersion(_Planned file) async {
    final original = file.original;
    if (original == null) return;
    final kept = File(_path('${file.name}.pre-csv-v2.bak'));
    if (await kept.exists()) return;
    await createFileExclusively(kept.path, utf8.encode(original));
  }
}

/// How the rows of one CSV are read, told apart and written.
final class _Codec<T, K> {
  const _Codec(this.file, this.decode, this.encode, this.key);

  final String file;
  final T? Function(List<String>) decode;
  final List<String> Function(T) encode;
  final K Function(T) key;

  String row(T value) => encodeCsvRecord(encode(value));

  /// The cells of a data row, or null for the header and blank lines. The
  /// width rule is the one a chapter move reads the file with too.
  List<String>? cells(CsvRecord record, int? header) =>
      dataCells(record, record.isBlank ? null : rowWidth(file, record, header));
}

const _reviewCodec = _Codec<Review, LineKey>(
  reviewsFile,
  decodeReview,
  encodeReview,
  _reviewKey,
);

const _streakCodec = _Codec<MoveStreak, StreakKey>(
  streaksFile,
  decodeStreak,
  encodeStreak,
  _streakKey,
);

LineKey _reviewKey(Review review) => review.key;

StreakKey _streakKey(MoveStreak streak) => (line: streak.key, ply: streak.ply);

final class _Planned {
  const _Planned(this.name, this.original, this.text);

  final String name;

  /// What the file held, or null when there was no file.
  final String? original;
  final String text;
}

final class _Unreadable implements Exception {
  _Unreadable(this.file, this.line);

  final String file;
  final int line;

  ProgressUnreadable get result => ProgressUnreadable(file, line);
}

final class _Changed implements Exception {
  _Changed(this.row);

  final String row;
}

sealed class ProgressRead {
  const ProgressRead();
}

final class ProgressLoaded extends ProgressRead {
  const ProgressLoaded({
    required this.reviews,
    required this.streaks,
    required this.mistakes,
  });

  final Map<LineKey, Review> reviews;
  final Map<StreakKey, MoveStreak> streaks;

  /// Wrong answers, oldest first.
  final List<Attempt> mistakes;
}

sealed class ProgressWrite {
  const ProgressWrite();
}

final class ProgressWritten extends ProgressWrite {
  const ProgressWritten();
}

/// Another session changed a row this write would have replaced.
final class ProgressConflict extends ProgressWrite {
  const ProgressConflict();
}

/// A file holds something that is not its rows; nothing was written to any.
final class ProgressUnreadable implements ProgressRead, ProgressWrite {
  const ProgressUnreadable(this.file, this.line);

  final String file;
  final int line;
}

final class ProgressFailed implements ProgressRead, ProgressWrite {
  const ProgressFailed(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

String _detail(Object error) => error is FileSystemException
    ? error.osError?.message ?? error.message
    : '$error';
