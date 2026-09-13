import 'dart:convert';

import 'package:path/path.dart' as p;

import '../storage/storage_service.dart';

/// Durable answers, independent of line ratings and their current chapter.
/// Storage is injected so owned file moves can repoint history without a
/// dependency on the review scheduler or the global storage factory.
class MoveAttemptStore {
  MoveAttemptStore(this.storage);
  final StorageService storage;
  static const fileName = 'repertoire_move_attempts.jsonl';

  Future<void> record({
    required String repertoireId,
    required String lineId,
    required int moveIndex,
    required String fen,
    required String playedSan,
    required String expectedSan,
    required bool correct,
    required String phase,
  }) async {
    final row = jsonEncode({
      'repertoireId': repertoireId,
      'lineId': lineId,
      'moveIndex': moveIndex,
      'fen': fen,
      'playedSan': playedSan,
      'expectedSan': expectedSan,
      'correct': correct,
      'phase': phase,
      'timestampUtc': DateTime.now().toUtc().toIso8601String(),
    });
    await storage.updateFile(fileName, (raw) => '${raw ?? ''}$row\n');
  }

  static List<Map<String, dynamic>> _decode(String? raw) => [
    for (final row in const LineSplitter().convert(raw ?? ''))
      if (row.trim().isNotEmpty) jsonDecode(row) as Map<String, dynamic>,
  ];

  Future<List<Map<String, dynamic>>> load({String? repertoireId}) async =>
      _decode(await storage.readFile(fileName))
          .where(
            (row) =>
                repertoireId == null || row['repertoireId'] == repertoireId,
          )
          .toList();

  /// Repoint selected lines, a whole chapter, or everything under a folder.
  /// The update reads the latest log while holding storage's mutation lock,
  /// preserving answers appended by another session since migration started.
  Future<void> repoint({
    required String from,
    String? to,
    Map<String, String> movedLinePaths = const {},
  }) async {
    if (to == null && movedLinePaths.isEmpty) return;
    if (await storage.readFile(fileName) == null) return;
    await storage.updateFile(fileName, (raw) {
      final rows = _decode(raw);
      var changed = false;
      for (final row in rows) {
        final source = row['repertoireId'] as String;
        final target = p.equals(source, from)
            ? movedLinePaths[row['lineId']] ?? to
            : to != null && p.isWithin(from, source)
            ? p.join(to, p.relative(source, from: from))
            : null;
        if (target != null && !p.equals(target, source)) {
          row['repertoireId'] = target;
          changed = true;
        }
      }
      return changed ? '${rows.map(jsonEncode).join('\n')}\n' : raw ?? '';
    });
  }
}
