import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;

import '../../features/settings/repositories/app_settings_repository.dart';
import '../../utils/atomic_file.dart';
import '../../utils/training_csv.dart';

/// Replayable path migration of every existing training format, then books.
/// Each file updates its latest contents under its existing atomic file lock.
/// A durable directory journal owns completion across files and preferences.
class RepertoireReferenceMigration {
  RepertoireReferenceMigration(this.documents, {this.books});
  final Directory documents;
  File _file(String name) => File(p.join(documents.path, name));
  final RepertoireBooksRepository? books;

  Future<void> repoint(String from, String to, String operationId) async {
    String move(String path) => p.equals(path, from)
        ? to
        : p.isWithin(from, path)
        ? p.join(to, p.relative(path, from: from))
        : path;
    for (final name in const [
      'repertoire_reviews.csv',
      'repertoire_review_history.csv',
      'repertoire_move_progress.csv',
      'repertoire_move_attempts.jsonl',
    ]) {
      if (await readTextFileSafely(_file(name)) == null) continue;
      await updateTextFileAtomically(_file(name), (raw) async {
        if (raw == null) {
          throw StateError('Training file disappeared during relocation');
        }
        String rewritten;
        if (name.endsWith('.jsonl')) {
          var changed = false;
          final rows = const LineSplitter()
              .convert(raw)
              .where((line) => line.trim().isNotEmpty)
              .map((line) {
                final value = jsonDecode(line) as Map<String, dynamic>;
                final old = value['repertoireId'] as String;
                final next = move(old);
                if (next != old) {
                  value['repertoireId'] = next;
                  changed = true;
                }
                return jsonEncode(value);
              })
              .toList();
          rewritten = changed ? '${rows.join('\n')}\n' : raw;
        } else {
          rewritten = _csv(raw, move);
        }
        if (rewritten == raw) return raw;
        final backup = p.join('.cap-reference-history', operationId, name);
        // Idempotent recovery retains the first pre-migration copy. This
        // callback holds the source lock; the backup uses its own directory.
        if (!await textFileExistsSafely(_file(backup))) {
          await writeTextFileAtomically(_file(backup), raw, createOnly: true);
        }
        return rewritten;
      });
    }
    await books?.relocate(from: from, to: to);
  }

  String _csv(String raw, String Function(String) move) {
    if (raw.trim().isEmpty) return raw;
    final rows = Csv(autoDetect: false, lineDelimiter: '\n').decode(raw);
    if (rows.isEmpty || rows.first.first != 'repertoire_id') {
      throw const FormatException(
        'Training header unavailable; refusing reference migration',
      );
    }
    final header = rows.first.map((value) => value.toString()).toList();
    var changed = false;
    final migrated = trainingRows(raw).map((row) {
      final cells = decodeTrainingRow(row, header.length);
      if (cells.length != header.length) {
        throw const FormatException('Invalid training row');
      }
      final next = move(cells.first);
      if (next != cells.first) {
        cells[0] = next;
        changed = true;
      }
      return encodeTrainingRow(cells);
    }).toList();
    return changed
        ? '${encodeTrainingRow(header)}\n${migrated.join('\n')}\n'
        : raw;
  }
}
