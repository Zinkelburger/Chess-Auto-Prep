/// One-time on-disk migrations the tactics database runs before its first
/// load: legacy CSV set files become PGN, and named sets from the multi-set
/// era move into the studies directory.
library;

import 'package:csv/csv.dart';

import '../../../services/storage/storage_service.dart';
import '../../../utils/log.dart';
import '../models/tactics_position.dart';
import 'tactics_pgn_codec.dart';

/// Parse tactics-CSV [content] (with header row) into positions.
/// Bad rows are reported as warnings instead of failing the whole file.
({List<TacticsPosition> positions, List<String> warnings}) parseTacticsCsv(
  String content,
) {
  final positions = <TacticsPosition>[];
  final warnings = <String>[];
  if (content.trim().isEmpty) {
    return (positions: positions, warnings: warnings);
  }
  final rows = Csv().decode(content);
  for (var i = 1; i < rows.length; i++) {
    try {
      positions.add(TacticsPosition.fromCsv(rows[i]));
    } catch (e) {
      warnings.add('Row $i: $e');
    }
  }
  return (positions: positions, warnings: warnings);
}

/// Runs the tactics-set migrations against one [StorageService].
class TacticsSetMigrations {
  TacticsSetMigrations(this._storage, {required this.defaultSetName});

  final StorageService _storage;

  /// Name of the single set file backing the tactics database.
  final String defaultSetName;

  /// Convert legacy `.csv` set files (pre-PGN installs) to `.pgn`. The CSV
  /// is renamed to `.csv.bak` after a successful conversion; a name that
  /// already has a `.pgn` file is left alone.
  ///
  /// Throws rather than convert lossily: a CSV with unreadable rows, or a
  /// set whose positions cannot all be encoded, needs repair first.
  Future<void> convertCsvSetsToPgn() async {
    for (final legacy in await _storage.listLegacyTacticsCsvSets()) {
      try {
        final pgnPath = await _storage.tacticsSetPath(legacy.name);
        if (await _storage.fileExists(pgnPath)) continue;
        final content = await _storage.readFile(legacy.path);
        if (content == null) continue;
        final parsed = parseTacticsCsv(content);
        if (parsed.warnings.isNotEmpty) {
          throw StateError('Legacy tactics CSV needs repair before migration');
        }
        final encoded = encodePuzzlesToPgn(legacy.name, parsed.positions);
        if (encoded.dropped != 0) {
          throw StateError('Refusing a lossy tactics migration');
        }
        await _storage.writeFile(pgnPath, encoded.pgn, createOnly: true);
        await _storage.renameFile(legacy.path, '${legacy.path}.bak');
        log.i(
          'Converted tactics set "${legacy.name}" from CSV to PGN '
          '(${parsed.positions.length} positions)',
        );
      } catch (e) {
        log.e('Error converting CSV set "${legacy.name}": $e');
        rethrow;
      }
    }
  }

  /// One-time cleanup from the multi-set era: tactics mode now owns a single
  /// database (the [defaultSetName] set), so any other set file is moved
  /// into the studies directory, where it stays reachable — studies are the
  /// curated-collection concept and can be reviewed as flashcards from
  /// Study mode. A name already taken in studies gets a ` (tactics)` suffix.
  Future<void> moveNamedSetsToStudies() async {
    for (final set in await _storage.listTacticsSets()) {
      if (set.name == defaultSetName) continue;
      try {
        final targetName = await _freeStudyName(set.name);
        await _storage.renameFile(
          set.filePath,
          await _storage.studyFilePath(targetName),
        );
        log.i('Moved tactics set "${set.name}" to studies as "$targetName"');
      } catch (e) {
        log.e('Error moving tactics set "${set.name}" to studies: $e');
      }
    }
  }

  Future<String> _freeStudyName(String setName) async {
    var targetName = setName;
    var suffix = 1;
    while (await _storage.fileExists(
      await _storage.studyFilePath(targetName),
    )) {
      suffix++;
      targetName = '$setName (tactics${suffix > 2 ? ' $suffix' : ''})';
    }
    return targetName;
  }
}
