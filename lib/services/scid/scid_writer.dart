/// Writes a Scid database — `<name>.si5`, `.sg5` and `.sn5` — from PGN games.
///
/// SCID5 rather than the older SCID4 because it is what upstream Scid creates
/// by default, it is the version whose format is fully specified (in
/// `src/codec_scid5.h`, the one file in that repo published under MIT), and it
/// lifts SCID4's ceilings from 16.7M games / 4 GB to 4 billion / 128 TB.
///
/// The three files are written together and only renamed into place once all
/// three are complete, so an interrupted export leaves no half-database that
/// Scid would try to open.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;

import '../../utils/file_operation_lock.dart';
import 'scid_game_encoder.dart';
import 'scid_index_entry.dart';
import 'scid_namebase.dart';

/// What one export produced.
class ScidWriteResult {
  const ScidWriteResult({
    required this.indexPath,
    required this.gamePath,
    required this.namePath,
    required this.games,
    required this.skipped,
    required this.truncated,
    required this.bytes,
  });

  final String indexPath;
  final String gamePath;
  final String namePath;

  /// Games written.
  final int games;

  /// Games that could not be encoded at all, with the reason.
  final List<String> skipped;

  /// Games written but cut short at an illegal move, with the move named.
  final List<String> truncated;

  /// Total size of the three files.
  final int bytes;

  List<String> get paths => [indexPath, gamePath, namePath];
}

/// Progress during an export.
typedef ScidWriteProgress = void Function(int gamesWritten, int? total);

class ScidWriter {
  ScidWriter._(this._idx, this._gme, this._nam, this._nameBase);

  final io.IOSink _idx;
  final io.IOSink _gme;
  final io.IOSink _nam;
  final ScidNameBase _nameBase;

  int _games = 0;
  int _offset = 0;
  final List<String> _skipped = [];
  final List<String> _truncated = [];

  /// Scid's own ceilings (`src/codec_scid5.h:167-172`).
  static const int maxGames = 0xFFFFFFFE;
  static const int maxGameBytes = 1 << 17;

  /// Write [games] to `<directory>/<name>.si5` and friends.
  ///
  /// [description] lands in the namebase as the database's own label, which
  /// is what Scid shows in its database list.
  static Future<ScidWriteResult> write({
    required String directory,
    required String name,
    required Stream<PgnGame<PgnNodeData>> games,
    String description = '',
    int? total,
    ScidWriteProgress? onProgress,
    FutureOr<bool> Function()? isCancelled,
  }) async {
    await io.Directory(directory).create(recursive: true);
    final safe = _safeName(name);
    final tmpSuffix = '.${DateTime.now().microsecondsSinceEpoch}.tmp';

    final idx = io.File(p.join(directory, '$safe.si5'));
    final gme = io.File(p.join(directory, '$safe.sg5'));
    final nam = io.File(p.join(directory, '$safe.sn5'));
    for (final file in <io.File>[idx, gme, nam]) {
      if (await file.exists()) {
        throw io.FileSystemException(
          'A Scid database with this name already exists; refusing to overwrite',
          file.path,
        );
      }
    }

    final idxTmp = io.File(p.join(directory, '$safe.si5$tmpSuffix'));
    final gmeTmp = io.File(p.join(directory, '$safe.sg5$tmpSuffix'));
    final namTmp = io.File(p.join(directory, '$safe.sn5$tmpSuffix'));

    final nameBase = ScidNameBase();
    // Slot 0 of the info entries is the description; Scid reads them in order.
    nameBase.addDbInfo(description);

    final writer = ScidWriter._(
      idxTmp.openWrite(),
      gmeTmp.openWrite(),
      namTmp.openWrite(),
      nameBase,
    );

    try {
      try {
        await for (final game in games) {
          if (isCancelled != null && await isCancelled()) break;
          writer._add(game);
          onProgress?.call(writer._games, total);
        }
        // The namebase is only known once every game has been seen.
        writer._nam.add(nameBase.toBytes());

        await writer._idx.flush();
        await writer._gme.flush();
        await writer._nam.flush();
      } finally {
        await writer._idx.close();
        await writer._gme.close();
        await writer._nam.close();
      }

      // Commit only when all three are complete, and never overwrite an
      // existing database. If installation fails, remove only files created
      // by this attempt; there was no older destination to lose.
      await withFileOperationLock(directory, () async {
        final destinations = <io.File>[idx, gme, nam];
        for (final file in destinations) {
          if (await file.exists()) {
            throw io.FileSystemException(
              'A Scid database with this name appeared during export; '
              'refusing to overwrite it',
              file.path,
            );
          }
        }
        final installed = <io.File>[];
        try {
          await idxTmp.rename(idx.path);
          installed.add(idx);
          await gmeTmp.rename(gme.path);
          installed.add(gme);
          await namTmp.rename(nam.path);
          installed.add(nam);
        } catch (_) {
          for (final file in installed.reversed) {
            if (await file.exists()) await file.delete();
          }
          rethrow;
        }
      });
    } finally {
      for (final file in <io.File>[idxTmp, gmeTmp, namTmp]) {
        if (await file.exists()) await file.delete();
      }
    }

    final bytes = await idx.length() + await gme.length() + await nam.length();

    return ScidWriteResult(
      indexPath: idx.path,
      gamePath: gme.path,
      namePath: nam.path,
      games: writer._games,
      skipped: writer._skipped,
      truncated: writer._truncated,
      bytes: bytes,
    );
  }

  void _add(PgnGame<PgnNodeData> game) {
    if (_games >= maxGames) {
      _skipped.add('database is full at $maxGames games');
      return;
    }
    final ScidEncodedGame encoded;
    try {
      encoded = ScidGameEncoder.encode(game);
    } on ScidEncodeException catch (e) {
      _skipped.add(_label(game, e.message));
      return;
    } catch (e) {
      _skipped.add(_label(game, '$e'));
      return;
    }

    if (encoded.data.length >= maxGameBytes) {
      _skipped.add(_label(game, 'game data exceeds Scid\'s 128 KB limit'));
      return;
    }
    if (encoded.truncatedAt != null) {
      _truncated.add(_label(game, 'stopped at ${encoded.truncatedAt}'));
    }

    final h = game.headers;
    final entry = ScidIndexEntry(
      whiteId: _nameBase.idFor(ScidNameType.player, h['White'] ?? '?'),
      blackId: _nameBase.idFor(ScidNameType.player, h['Black'] ?? '?'),
      eventId: _nameBase.idFor(ScidNameType.event, h['Event'] ?? '?'),
      siteId: _nameBase.idFor(ScidNameType.site, h['Site'] ?? '?'),
      roundId: _nameBase.idFor(ScidNameType.round, h['Round'] ?? '?'),
      whiteElo: _elo(h['WhiteElo']),
      blackElo: _elo(h['BlackElo']),
      date: scidDate(h['Date']),
      eventDate: scidDate(h['EventDate']),
      plyCount: encoded.plyCount > 1023 ? 1023 : encoded.plyCount,
      dataLength: encoded.data.length,
      dataOffset: _offset,
      finalMaterial: encoded.finalMaterial,
      homePawnData: encoded.homePawnData,
      homePawnCount: encoded.homePawnCount,
      flags: ScidIndexEntry.flagsFor(
        ownStart: encoded.nonStandardStart,
        promotions: encoded.hasPromotion,
        underPromotions: encoded.hasUnderPromotion,
      ),
      result: ScidResult.fromPgn(h['Result']),
      eco: scidEco(h['ECO']),
      commentRating: scidCountRating(encoded.commentCount),
      variationRating: scidCountRating(encoded.variationCount),
      nagRating: scidCountRating(encoded.nagCount),
    );

    _idx.add(entry.toBytesV5());
    _gme.add(encoded.data);
    _offset += encoded.data.length;
    _games++;
  }

  static int _elo(String? raw) {
    final v = int.tryParse(raw?.trim() ?? '') ?? 0;
    return v < 0 ? 0 : (v > 4000 ? 4000 : v);
  }

  static String _label(PgnGame<PgnNodeData> game, String why) {
    final w = game.headers['White'] ?? '?';
    final b = game.headers['Black'] ?? '?';
    return '$w - $b: $why';
  }

  /// Scid picks the database name off the filename, so keep it to characters
  /// every platform and Scid's own file dialogs handle.
  static String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    return cleaned.isEmpty ? 'export' : cleaned;
  }
}
