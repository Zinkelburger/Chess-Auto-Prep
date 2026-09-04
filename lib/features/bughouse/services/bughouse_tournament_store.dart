/// Where bughouse matches live: one directory per match under
/// `Documents/bughouse_matches/`, holding `match.json` (config plus every
/// game) and `games.bpgn` (the games themselves).
///
/// The split mirrors the engine tournament's, and so does the reasoning, but
/// the portable half is **BPGN** rather than PGN. That is not a stylistic
/// choice: a bughouse game is two boards interleaved in real time, and PGN has
/// nowhere to put the second one. BPGN is the format bughouse-db.org publishes
/// and `tools/bughouse_db/bpgn.py` already reads — so a match exported here
/// can be indexed into the same opening book as twenty-one years of FICS
/// games, and a `1-0` means the same thing in both.
///
/// Pure `dart:io`, no Flutter, so a headless caller could use the same store.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' hide File;
import 'package:path/path.dart' as p;

import '../../../services/storage/file_mutation_service.dart';
import '../../../utils/atomic_file.dart';
import '../../../models/game_outcome.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_state.dart';
import '../models/bughouse_tournament.dart';
import 'bughouse_tournament_runner.dart';

const String kBughouseMatchesDirectoryName = 'bughouse_matches';
const String _kMetadataFile = 'match.json';
const String _kBpgnFile = 'games.bpgn';

class BughouseTournamentStore {
  BughouseTournamentStore(this.root);

  /// `Documents/bughouse_matches`.
  final Directory root;

  Future<void> ensureRoot() async {
    if (!await root.exists()) await root.create(recursive: true);
  }

  String directoryFor(String id) => p.join(root.path, id);
  String metadataPathFor(String id) => p.join(root.path, id, _kMetadataFile);
  String bpgnPathFor(String id) => p.join(root.path, id, _kBpgnFile);

  /// Newest first.
  Future<List<StoredBughouseTournament>> list() async {
    if (!await root.exists()) return const [];
    final out = <StoredBughouseTournament>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (p.basename(entity.path).startsWith('.')) continue;
      final loaded = await load(p.basename(entity.path));
      if (loaded != null) out.add(loaded);
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<StoredBughouseTournament?> load(String id) async {
    final file = File(metadataPathFor(id));
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return StoredBughouseTournament.fromJson(
        Map<String, dynamic>.from(json),
        directoryPath: directoryFor(id),
      );
    } catch (_) {
      // A half-written or hand-edited file should hide one match, not break
      // the list.
      return null;
    }
  }

  Future<StoredBughouseTournament> create(
    BughouseTournamentConfig config,
  ) async {
    await ensureRoot();
    final id = await _allocateId(config.name);
    final dir = Directory(directoryFor(id));
    await dir.create(recursive: true);
    final match = StoredBughouseTournament(
      id: id,
      directoryPath: dir.path,
      config: config,
      createdAt: DateTime.now(),
      status: BughouseTournamentStatus.pending,
    );
    await save(match);
    return match;
  }

  /// Writes both files: the metadata and the BPGN beside it.
  Future<void> save(StoredBughouseTournament match) async {
    final file = File(metadataPathFor(match.id));
    await file.parent.create(recursive: true);
    await writeTextFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(match.toJson()),
    );
    await writeTextFileAtomically(
      File(bpgnPathFor(match.id)),
      writeMatchBpgn(match),
    );
  }

  Future<void> delete(String id) async {
    final dir = Directory(directoryFor(id));
    await FileMutationService.instance.quarantineDirectory(
      dir,
      allowedRoot: root,
      quarantineRoot: Directory(p.join(root.path, '.trash')),
    );
  }

  Future<void> rename(String id, String newName) async {
    final match = await load(id);
    if (match == null) return;
    await save(match.copyWith(config: match.config.copyWith(name: newName)));
  }

  Future<String> _allocateId(String name) async {
    final base = _slugify(name);
    var candidate = base;
    var suffix = 2;
    while (await Directory(directoryFor(candidate)).exists()) {
      candidate = '$base-$suffix';
      suffix++;
    }
    return candidate;
  }
}

String _slugify(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'match' : slug;
}

// --------------------------------------------------------------------- BPGN

/// The whole match as one BPGN file.
String writeMatchBpgn(StoredBughouseTournament match) {
  final start = match.config.startState;
  final out = StringBuffer();
  for (final game in match.games) {
    out
      ..write(writeGameBpgn(match, game, start: start))
      ..writeln();
  }
  return out.toString();
}

/// One game in BPGN.
///
/// The four player tags are the format's own: `WhiteA` and `BlackB` are
/// partners, and so are `BlackA` and `WhiteB`, because partners sit on
/// opposite colours. A participant therefore appears **twice**, once per seat,
/// which is what makes a two-name match into a four-name game.
///
/// The movetext is `1A. d4 1B. e4 1a. d5` — number, board letter, and the
/// letter's case for the mover. It is written in the order the moves were
/// actually played, which is the whole point of the format and is exactly what
/// [BughouseGameRecord.moves] preserves.
String writeGameBpgn(
  StoredBughouseTournament match,
  BughouseGameRecord game, {
  BughouseState? start,
}) {
  final config = match.config;
  final root = start ?? config.startState;
  final out = StringBuffer()
    ..writeln('[Event "${_escape(config.name)}"]')
    ..writeln('[Site "Chess Auto Prep"]')
    ..writeln('[Date "${_date(game.startedAt)}"]')
    ..writeln('[Round "${game.round}"]')
    ..writeln('[WhiteA "${_escape(game.whiteName)}"]')
    ..writeln('[BlackA "${_escape(game.blackName)}"]')
    // Partners cross over: the pair holding White on board 1 holds Black on
    // board 2.
    ..writeln('[WhiteB "${_escape(game.blackName)}"]')
    ..writeln('[BlackB "${_escape(game.whiteName)}"]')
    ..writeln('[Result "${game.result.pgnToken}"]')
    ..writeln('[Termination "${game.termination.pgnTag}"]');
  if (config.openingLabel.isNotEmpty) {
    out.writeln('[Opening "${_escape(config.openingLabel)}"]');
  }
  if (root != null && root.dualFen != BughouseState.initial().dualFen) {
    // Not a BPGN standard tag, but a match from a set-up position is
    // unreplayable without it, and an unknown tag is ignored by every reader.
    out.writeln('[SetUpDualFEN "${root.dualFen}"]');
  }
  out.writeln();

  if (root != null) {
    final line = replayBughouseGame(root, game.moves);
    out.writeln(_movetext(line));
  }
  out.writeln(game.result.pgnToken);
  return out.toString();
}

/// The interleaved movetext, in the order the plies were played.
String _movetext(BughouseHistory line) {
  final tokens = <String>[];
  for (final ply in line.plies) {
    final letter = ply.board == BughouseBoard.a ? 'A' : 'B';
    tokens.add(
      '${ply.moveNumber}${ply.side == Side.white ? letter : letter.toLowerCase()}.'
      ' ${ply.san}',
    );
  }
  // Wrapped at 80 columns, the way every PGN writer does, so the file reads in
  // a terminal.
  final wrapped = StringBuffer();
  var width = 0;
  for (final token in tokens) {
    if (width > 0 && width + token.length + 1 > 80) {
      wrapped.writeln();
      width = 0;
    } else if (width > 0) {
      wrapped.write(' ');
      width += 1;
    }
    wrapped.write(token);
    width += token.length;
  }
  return wrapped.toString();
}

String _date(DateTime when) =>
    '${when.year}.${_two(when.month)}.${_two(when.day)}';

String _two(int value) => value.toString().padLeft(2, '0');

String _escape(String value) => value.replaceAll('"', "'");
