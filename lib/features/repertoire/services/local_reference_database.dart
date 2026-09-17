/// A disposable, disk-backed opening index for a user's PGN file.
/// Source files stay untouched; only one game at a time is parsed while indexing.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../models/pgn_game_entry.dart';
import '../../../services/storage/file_mutation_service.dart';
import '../../../utils/fen_utils.dart';
import '../../../utils/chess_utils.dart' show moveToStandardUci;

class ReferenceMove {
  const ReferenceMove(
    this.san,
    this.uci,
    this.games,
    this.white,
    this.draws,
    this.black,
  );
  final String san;
  final String uci;
  final int games;
  final int white;
  final int draws;
  final int black;
}

class ReferencePosition {
  const ReferencePosition({
    required this.moves,
    required this.games,
    required this.total,
    required this.offset,
  });
  final List<ReferenceMove> moves;
  final List<PgnGameEntry> games;
  final int total;
  final int offset;
}

class ReferenceIndex {
  const ReferenceIndex({
    required this.path,
    required this.source,
    required this.games,
    required this.skipped,
  });
  final String path;
  final String source;
  final int games;
  final int skipped;
}

/// Explicit data for the indexing isolate. The port carries imported-game counts.
class ReferenceIndexRequest {
  const ReferenceIndexRequest(
    this.source,
    this.cacheDirectory,
    this.progress, {
    this.stagingDirectory,
  });
  final String source;
  final String cacheDirectory;
  final SendPort? progress;
  final String? stagingDirectory;
}

/// Versioned cache keys include path, size and mtime, so replacing a PGN never
/// silently reuses its old opening statistics. Only completed indexes are reused.
Future<ReferenceIndex> buildReferenceIndex(
  ReferenceIndexRequest request,
) async {
  final source = File(p.normalize(p.absolute(request.source)));
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file) {
    throw StateError('PGN file not found');
  }
  final key = sha256.convert(
    utf8.encode(
      'v3|${source.path}|${before.size}|${before.modified.microsecondsSinceEpoch}',
    ),
  );
  await Directory(request.cacheDirectory).create(recursive: true);
  final target = p.join(request.cacheDirectory, '$key.sqlite');
  if (File(target).existsSync()) {
    try {
      final db = sqlite3.open(target, mode: OpenMode.readOnly);
      try {
        final row = db.select('SELECT games, skipped FROM metadata').single;
        return ReferenceIndex(
          path: target,
          source: source.path,
          games: row['games'] as int,
          skipped: row['skipped'] as int,
        );
      } finally {
        db.close();
      }
    } catch (error) {
      if (error is! SqliteException && error is! StateError) rethrow;
      // The index is reproducible cache data; a damaged copy can be rebuilt.
      await FileMutationService.instance.deleteDisposableFile(
        File(target),
        allowedRoot: Directory(request.cacheDirectory),
      );
    }
  }
  final temporary = p.join(
    request.stagingDirectory ?? request.cacheDirectory,
    '$key.${DateTime.now().microsecondsSinceEpoch}.building',
  );
  try {
    final db = sqlite3.open(temporary);
    var count = 0;
    var skipped = 0;
    try {
      db.execute('''
      PRAGMA journal_mode = MEMORY;
      PRAGMA cache_size = -8192;
      CREATE TABLE games(id INTEGER PRIMARY KEY, headers TEXT NOT NULL, pgn TEXT NOT NULL, search TEXT NOT NULL, date TEXT NOT NULL);
      CREATE TABLE positions(fen TEXT NOT NULL, date TEXT NOT NULL, game INTEGER NOT NULL, PRIMARY KEY(fen, date DESC, game DESC)) WITHOUT ROWID;
      CREATE TABLE book(fen TEXT NOT NULL, san TEXT NOT NULL, uci TEXT NOT NULL, games INTEGER NOT NULL, white INTEGER NOT NULL, draws INTEGER NOT NULL, black INTEGER NOT NULL, PRIMARY KEY(fen, uci)) WITHOUT ROWID;
      CREATE TABLE metadata(games INTEGER NOT NULL, skipped INTEGER NOT NULL);
    ''');
      final insert = db.prepare(
        'INSERT INTO games(headers, pgn, search, date) VALUES(?,?,?,?)',
      );
      final position = db.prepare(
        'INSERT OR IGNORE INTO positions VALUES(?,?,?)',
      );
      final move = db.prepare(
        '''INSERT INTO book VALUES(?,?,?,1,?,?,?)
      ON CONFLICT(fen, uci) DO UPDATE SET games=games+1, white=white+excluded.white, draws=draws+excluded.draws, black=black+excluded.black''',
      );
      db.execute('BEGIN');
      try {
        await for (final raw in streamReferenceGames(source)) {
          // Reject unplayable mainlines as a whole: partial games must not bias
          // the opening counts. Annotations and variations remain in the raw PGN.
          final List<({String fen, String san, String uci})> edges = [];
          late PgnGame<PgnNodeData> game;
          late Position pos;
          try {
            game = parsePgnGame(raw);
            pos = game.headers['FEN'] == null
                ? Chess.initial
                : Chess.fromSetup(Setup.parseFen(game.headers['FEN']!));
            if (game.headers['Variant'] != null &&
                !{'Standard', 'Chess'}.contains(game.headers['Variant'])) {
              throw const FormatException('Unsupported variant');
            }
            for (final node in game.moves.mainline()) {
              final played = pos.parseSan(node.san);
              if (played == null) {
                throw const FormatException('Illegal mainline');
              }
              final (next, san) = pos.makeSan(played);
              edges.add((
                fen: normalizeFen(pos.fen),
                san: san,
                uci: moveToStandardUci(pos, played),
              ));
              pos = next;
            }
            if (edges.isEmpty) throw const FormatException('No moves');
          } catch (_) {
            skipped++;
            continue;
          }
          final h = game.headers;
          insert.execute([
            jsonEncode(h),
            raw,
            [
              'White',
              'Black',
              'Event',
              'Site',
              'ECO',
            ].map((key) => h[key] ?? '').join(' ').toLowerCase(),
            h['Date'] ?? '',
          ]);
          final id = db.lastInsertRowId;
          final seen = <String>{};
          final result = h['Result'];
          for (final edge in edges) {
            if (!seen.add(edge.fen)) continue;
            position.execute([edge.fen, h['Date'] ?? '', id]);
            move.execute([
              edge.fen,
              edge.san,
              edge.uci,
              result == '1-0' ? 1 : 0,
              result == '1/2-1/2' ? 1 : 0,
              result == '0-1' ? 1 : 0,
            ]);
          }
          position.execute([normalizeFen(pos.fen), h['Date'] ?? '', id]);
          count++;
          if (count % 250 == 0) {
            db.execute('COMMIT');
            request.progress?.send(count);
            db.execute('BEGIN');
          }
        }
        db.execute('INSERT INTO metadata VALUES(?,?)', [count, skipped]);
        db.execute('COMMIT');
      } finally {
        insert.close();
        position.close();
        move.close();
      }
      final after = await source.stat();
      if (before.size != after.size || before.modified != after.modified) {
        throw StateError('The PGN changed while indexing. Open it again.');
      }
      if (count == 0) {
        throw StateError(
          'No playable standard-chess games found ($skipped skipped).',
        );
      }
    } finally {
      db.close();
    }
    // A killed build never replaces a usable index; .building files are disposable.
    try {
      await FileMutationService.instance.moveFileNoReplace(
        File(temporary),
        File(target),
        allowedRoot: Directory(request.cacheDirectory),
      );
    } on FileSystemException {
      // Another pane may have finished the same immutable source concurrently.
      if (!await File(target).exists()) rethrow;
      await FileMutationService.instance.deleteDisposableFile(
        File(temporary),
        allowedRoot: Directory(request.cacheDirectory),
      );
    }
    return ReferenceIndex(
      path: target,
      source: source.path,
      games: count,
      skipped: skipped,
    );
  } finally {
    await FileMutationService.instance.deleteDisposableFile(
      File(temporary),
      allowedRoot: Directory(request.cacheDirectory),
    );
  }
}

/// Streaming PGN boundaries: a tag following movetext starts a new game.
/// Brace comments can span lines containing apparent tags; those are not cuts.
Stream<String> streamReferenceGames(File source) async* {
  var buffer = StringBuffer();
  var hasMoves = false;
  var inComment = false;
  var firstLine = true;
  await for (var line
      in source
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
    if (firstLine) {
      line = line.replaceFirst(RegExp('^\uFEFF'), '');
      firstLine = false;
    }
    final text = line.trim();
    if (!inComment && text.startsWith('%')) continue;
    final tag = !inComment && RegExp(r'^\[\w+\s+"').hasMatch(text);
    if (tag && hasMoves) {
      yield buffer.toString();
      buffer = StringBuffer();
      hasMoves = false;
    }
    buffer.writeln(line);
    if (tag) continue;
    for (final rune in line.runes) {
      if (inComment) {
        if (rune == 125) inComment = false;
      } else if (rune == 59) {
        break;
      } else if (rune == 123) {
        inComment = true;
      } else if (rune > 32) {
        hasMoves = true;
      }
    }
  }
  if (buffer.toString().trim().isNotEmpty) yield buffer.toString();
}

/// All-position counts are pre-aggregated. Game pages fetch only their own PGNs.
/// The position index is date-ordered, avoiding a sort of every matching game.
/// Run off the UI isolate: broad positions and text searches may match many games.
ReferencePosition queryReferencePosition(
  ({String path, String fen, String search, int offset, int limit}) request,
) {
  final db = sqlite3.open(request.path, mode: OpenMode.readOnly);
  try {
    final fen = normalizeFen(request.fen);
    final rows = db.select(
      'SELECT * FROM book WHERE fen=? ORDER BY games DESC, san',
      [fen],
    );
    final search = request.search.trim().toLowerCase();
    const from = 'FROM positions p JOIN games g ON g.id=p.game WHERE p.fen=?';
    final where = search.isEmpty ? from : '$from AND instr(g.search, ?) > 0';
    final args = <Object?>[fen, if (search.isNotEmpty) search];
    final total =
        db.select('SELECT COUNT(*) n $where', args).single['n'] as int;
    final games = db.select(
      'SELECT g.headers, g.pgn $where ORDER BY p.date DESC, p.game DESC LIMIT ? OFFSET ?',
      [...args, request.limit, request.offset],
    );
    return ReferencePosition(
      moves: [
        for (final r in rows)
          ReferenceMove(
            r['san'] as String,
            r['uci'] as String,
            r['games'] as int,
            r['white'] as int,
            r['draws'] as int,
            r['black'] as int,
          ),
      ],
      games: [
        for (final r in games)
          PgnGameEntry(
            headers: (jsonDecode(r['headers'] as String) as Map)
                .cast<String, String>(),
            pgnText: r['pgn'] as String,
          ),
      ],
      total: total,
      offset: request.offset,
    );
  } finally {
    db.close();
  }
}
