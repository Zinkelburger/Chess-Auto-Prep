/// Headless driver for the Engine Tournament feature.
///
/// Runs the *same* services the app runs (`EngineTournamentRunner`,
/// `EngineGameRunner`, `TournamentStore`) without a Flutter engine, and
/// writes into the same `Documents/engine_tournaments/` tree, so a match
/// started here shows up in the app's Engine Tournament screen next launch.
///
///   dart run tools/run_engine_tournament.dart \
///     --name "Stockfish self-match" \
///     --fen "3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1" \
///     --games 10 --movetime 2000
///
/// Engines default to the bundled Stockfish playing itself. Add
/// `--engine "Name=/path/to/binary"` (repeatable) for anything else.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/adjudication_rules.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/stored_tournament.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/crosstable_builder.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_registry.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_tournament_runner.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_verification.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/tournament_store.dart';
import 'package:path/path.dart' as p;

Future<int> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args.help) {
    stdout.writeln(_usage);
    return 0;
  }

  // `--verify <path>` is the engine-manager check, headless: the MCP tools
  // use it to vet a binary before writing it into engines.json, and it runs
  // nothing else.
  final verifyPath = args.verify;
  if (verifyPath != null) {
    final report = await verifyUciEngine(verifyPath);
    stdout.writeln(
      jsonEncode({
        'ok': report.ok,
        'path': verifyPath,
        'message': report.message,
        'name': report.name,
        'author': report.author,
        'sampleMove': report.sampleMove,
        'options': report.options.map((o) => o.name).toList(),
        'transcript': report.transcript.take(12).toList(),
      }),
    );
    return report.ok ? 0 : 3;
  }

  final root = Directory(
    args.root ?? p.join(_documentsDirectory(), kEngineTournamentsDirectoryName),
  );

  // `--show <id>` prints one saved tournament's crosstable, rendered and as
  // JSON. It exists so the MCP tools never have to re-implement the standings
  // maths in another language — there is one implementation of Elo, SB and
  // LOS, and this is how everything else reaches it.
  final showId = args.show;
  if (showId != null) {
    final store = TournamentStore(root);
    final tournament = await store.load(showId);
    if (tournament == null) {
      stdout.writeln(
        jsonEncode({
          'ok': false,
          'error': 'No tournament "$showId" in ${root.path}',
        }),
      );
      return 4;
    }
    stdout.writeln(jsonEncode(_showPayload(tournament)));
    return 0;
  }

  // ── Engines ──────────────────────────────────────────────────────────────
  final specs = <EngineSpec>[];
  final paths = <String, String>{};
  if (args.engines.isEmpty) {
    final stockfish = args.stockfish ?? _findBundledStockfish();
    if (stockfish == null) {
      stderr.writeln(
        'Could not find the app\'s Stockfish. Launch the app once so it '
        'extracts the binary, or pass --stockfish <path>.',
      );
      return 2;
    }
    for (var i = 0; i < 2; i++) {
      final spec = EngineSpec(
        id: 'stockfish-${i + 1}',
        name: 'Stockfish ${String.fromCharCode(65 + i)}',
        executablePath: stockfish,
      );
      specs.add(spec);
      paths[spec.id] = stockfish;
    }
  } else {
    for (final entry in args.engines) {
      final split = entry.indexOf('=');
      final name = split < 0 ? p.basename(entry) : entry.substring(0, split);
      final path = split < 0 ? entry : entry.substring(split + 1);
      final spec = EngineSpec(
        id: newEngineId(),
        name: name,
        executablePath: path,
      );
      specs.add(spec);
      paths[spec.id] = path;
    }
  }

  stdout.writeln('Verifying ${specs.length} engine(s)…');
  final verifiedPaths = <String>{};
  for (final spec in specs) {
    final path = paths[spec.id]!;
    if (!verifiedPaths.add(path)) continue;
    final report = await verifyUciEngine(path);
    stdout.writeln(
      '  ${report.ok ? "ok" : "FAIL"}  $path\n'
      '        ${report.ok ? "${report.name} — played ${report.sampleMove}" : report.message}',
    );
    if (!report.ok) return 3;
  }

  // ── Config ───────────────────────────────────────────────────────────────
  final config = TournamentConfig(
    name: args.name,
    engines: specs,
    startFen: args.fen ?? kStandardStartFen,
    openingLabel: args.opening,
    timeControl: args.timeControl,
    gamesPerPairing: args.games,
    concurrency: args.concurrency,
    adjudication: const AdjudicationRules(),
  );

  final store = TournamentStore(root);
  final tournament = await store.create(config);

  // One machine-readable line as soon as the directory exists, before any
  // engine thinks. A caller that launched this detached — the MCP
  // `tournament_run` tool — has no other way to learn the id it allocated.
  stdout.writeln(
    'TOURNAMENT ${jsonEncode({'id': tournament.id, 'directory': tournament.directoryPath, 'pgn': tournament.pgnPath, 'metadata': store.metadataPathFor(tournament.id), 'totalGames': config.totalGames, 'timeControl': config.timeControl.label, 'startFen': config.startFen})}',
  );
  stdout
    ..writeln('')
    ..writeln('Tournament "${config.name}" → ${tournament.directoryPath}')
    ..writeln('  position   ${config.startFen}')
    ..writeln('  control    ${config.timeControl.label}')
    ..writeln('  games      ${config.totalGames}')
    ..writeln('  concurrency ${config.concurrency}')
    ..writeln('');

  final runner = EngineTournamentRunner(
    store: store,
    resolveExecutable: (spec) async =>
        spec.executablePath ?? paths[spec.id] ?? '',
    onLog: (message) => stdout.writeln('  $message'),
  );

  // Ctrl-C stops cleanly rather than orphaning engine processes. The
  // subscription is cancelled below: a live signal listener keeps the VM's
  // event loop alive and the process would never exit.
  final interrupts = ProcessSignal.sigint.watch().listen((_) {
    stdout.writeln('\nStopping after the current game…');
    runner.cancel();
  });

  final finished = await runner.run(tournament);
  await interrupts.cancel();

  stdout.writeln('');
  stdout.writeln(_renderCrosstable(finished.config, finished.games));
  stdout
    ..writeln('')
    ..writeln('Status: ${finished.status.name}')
    ..writeln('PGN:    ${finished.pgnPath}')
    ..writeln('Meta:   ${store.metadataPathFor(finished.id)}');
  if (finished.error != null) stderr.writeln('Error: ${finished.error}');
  return finished.error == null ? 0 : 1;
}

/// Everything `--show` reports about one tournament.
Map<String, dynamic> _showPayload(StoredTournament tournament) {
  final config = tournament.config;
  final table = buildCrosstable(config, tournament.games);
  return {
    'ok': true,
    'id': tournament.id,
    'name': config.name,
    'status': tournament.status.name,
    'createdAt': tournament.createdAt.toIso8601String(),
    'finishedAt': tournament.finishedAt?.toIso8601String(),
    'error': tournament.error,
    'startFen': config.startFen,
    'opening': config.openingLabel,
    'timeControl': config.timeControl.label,
    'format': config.format.name,
    'concurrency': config.concurrency,
    'gamesPlayed': tournament.gamesPlayed,
    'gamesTotal': tournament.gamesTotal,
    'directory': tournament.directoryPath,
    'pgn': tournament.pgnPath,
    'engines': config.engines.map((e) => e.name).toList(),
    'standings': [
      for (final row in table.standings)
        {
          'rank': row.rank,
          'engineIndex': row.engineIndex,
          'name': row.name,
          'points': row.points,
          'played': row.played,
          'wins': row.wins,
          'draws': row.draws,
          'losses': row.losses,
          'score': row.scoreLabel,
          'scorePercent': row.scoreFraction * 100,
          'drawPercent': row.drawFraction * 100,
          'sonnebornBerger': row.sonnebornBerger,
          'eloDiff': row.eloDiff,
          'eloMargin': row.eloMargin,
          'likelihoodOfSuperiority': row.likelihoodOfSuperiority * 100,
        },
    ],
    'headToHead': {
      for (final row in table.standings)
        row.name: {
          for (final other in table.standings)
            if (table.cell(row.engineIndex, other.engineIndex) case final cell?)
              other.name: {
                'points': cell.points,
                'played': cell.played,
                'results': cell.results.join(),
              },
        },
    },
    'games': [
      for (final game in tournament.games)
        {
          'number': game.gameNumber,
          'round': game.round,
          'white': game.whiteName,
          'black': game.blackName,
          'result': game.result.pgnToken,
          'termination': game.termination.label,
          'detail': game.detail,
          'plies': game.plies,
          'seconds': game.durationMs / 1000,
        },
    ],
    'text': _renderCrosstable(config, tournament.games),
  };
}

String _renderCrosstable(TournamentConfig config, List games) {
  final table = buildCrosstable(config, games.cast());
  final buffer = StringBuffer()
    ..writeln('Crosstable')
    ..writeln('=' * 78);
  final nameWidth = table.standings
      .map((r) => r.name.length)
      .fold<int>(6, (a, b) => a > b ? a : b);
  buffer.writeln(
    '${"#".padLeft(2)}  ${"Engine".padRight(nameWidth)}  '
    '${"Score".padLeft(8)}  ${"W".padLeft(3)} ${"D".padLeft(3)} ${"L".padLeft(3)}  '
    '${"Draw%".padLeft(6)}  ${"Elo".padLeft(14)}  ${"LOS".padLeft(6)}  SB',
  );
  for (final row in table.standings) {
    final elo = row.eloDiff == null
        ? '—'
        : '${row.eloDiff! >= 0 ? '+' : ''}${row.eloDiff!.toStringAsFixed(0)}'
              '${row.eloMargin == null ? '' : ' ±${row.eloMargin!.toStringAsFixed(0)}'}';
    buffer.writeln(
      '${row.rank.toString().padLeft(2)}  ${row.name.padRight(nameWidth)}  '
      '${row.scoreLabel.padLeft(8)}  ${row.wins.toString().padLeft(3)} '
      '${row.draws.toString().padLeft(3)} ${row.losses.toString().padLeft(3)}  '
      '${(row.drawFraction * 100).toStringAsFixed(0).padLeft(5)}%  '
      '${elo.padLeft(14)}  '
      '${(row.likelihoodOfSuperiority * 100).toStringAsFixed(1).padLeft(5)}%  '
      '${row.sonnebornBerger.toStringAsFixed(2)}',
    );
  }
  buffer.writeln('');
  for (final row in table.standings) {
    for (final other in table.standings) {
      final cell = table.cell(row.engineIndex, other.engineIndex);
      if (cell == null) continue;
      buffer.writeln(
        '  ${row.name} vs ${other.name}: '
        '${cell.points.toStringAsFixed(1)}/${cell.played}  '
        '${cell.results.join()}',
      );
    }
  }
  return buffer.toString();
}

String _documentsDirectory() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  final xdg = Platform.environment['XDG_DOCUMENTS_DIR'];
  if (xdg != null && xdg.isNotEmpty) return xdg;
  return p.join(home, 'Documents');
}

/// The engine the app extracted on first launch, wherever path_provider put
/// its support directory on this machine.
String? _findBundledStockfish() {
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final name = Platform.isWindows
      ? 'stockfish-windows.exe'
      : Platform.isMacOS
      ? 'stockfish-macos'
      : 'stockfish-linux';
  final roots = [
    p.join(home, '.local', 'share'),
    p.join(home, 'Library', 'Application Support'),
  ];
  for (final rootPath in roots) {
    final root = Directory(rootPath);
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final candidate = File(p.join(entity.path, name));
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

const _usage = '''
Run an engine-vs-engine tournament headlessly.

  --name <text>        Tournament name (default "Engine match")
  --fen <fen>          Starting position (default: standard start)
  --opening <text>     Label for the PGN Opening tag
  --games <n>          Games per pairing (default 10)
  --movetime <ms>      Fixed think time per move (default 2000)
  --tc <base+inc>      Clock in seconds instead, e.g. 60+0.6 or 40/60+0.6
  --depth <n>          Fixed depth instead of a clock
  --concurrency <n>    Games in flight at once (default 1)
  --engine <Name=path> A UCI engine (repeatable; default: bundled Stockfish
                       playing itself)
  --stockfish <path>   Override the bundled-Stockfish lookup
  --root <dir>         Tournaments directory (default
                       ~/Documents/engine_tournaments)
  --verify <path>      Check one binary is a working UCI engine and print the
                       report as JSON; runs nothing else
  --show <id>          Print a saved tournament (crosstable, standings, games)
                       as JSON and exit
  -h, --help
''';

class _Args {
  _Args({
    required this.name,
    required this.fen,
    required this.opening,
    required this.games,
    required this.concurrency,
    required this.timeControl,
    required this.engines,
    required this.stockfish,
    required this.root,
    required this.verify,
    required this.show,
    required this.help,
  });

  final String name;
  final String? fen;
  final String opening;
  final int games;
  final int concurrency;
  final TimeControl timeControl;
  final List<String> engines;
  final String? stockfish;
  final String? root;

  /// `--verify <path>`: check one binary and print the report as JSON.
  final String? verify;

  /// `--show <id>`: print one saved tournament as JSON and exit.
  final String? show;

  final bool help;

  static _Args parse(List<String> argv) {
    var name = 'Engine match';
    String? fen;
    var opening = '';
    var games = 10;
    var concurrency = 1;
    var timeControl = const TimeControl.perMove(2000);
    final engines = <String>[];
    String? stockfish;
    String? root;
    String? verify;
    String? show;
    var help = false;

    for (var i = 0; i < argv.length; i++) {
      String next() => i + 1 < argv.length ? argv[++i] : '';
      switch (argv[i]) {
        case '--name':
          name = next();
        case '--fen':
          fen = next();
        case '--opening':
          opening = next();
        case '--games':
          games = int.tryParse(next()) ?? games;
        case '--concurrency':
          concurrency = int.tryParse(next()) ?? concurrency;
        case '--movetime':
          timeControl = TimeControl.perMove(int.tryParse(next()) ?? 2000);
        case '--depth':
          timeControl = TimeControl.fixedDepth(int.tryParse(next()) ?? 12);
        case '--tc':
          timeControl = _parseTc(next()) ?? timeControl;
        case '--engine':
          engines.add(next());
        case '--stockfish':
          stockfish = next();
        case '--root':
          root = next();
        case '--verify':
          verify = next();
        case '--show':
          show = next();
        case '-h':
        case '--help':
          help = true;
      }
    }
    return _Args(
      name: name,
      fen: fen,
      opening: opening,
      games: games,
      concurrency: concurrency,
      timeControl: timeControl,
      engines: engines,
      stockfish: stockfish,
      root: root,
      verify: verify,
      show: show,
      help: help,
    );
  }

  /// `60+0.6` / `40/60+0.6` / `120`, in seconds — cutechess's spelling.
  static TimeControl? _parseTc(String text) {
    final match = RegExp(
      r'^(?:(\d+)/)?([\d.]+)(?:\+([\d.]+))?$',
    ).firstMatch(text.trim());
    if (match == null) return null;
    final base = double.tryParse(match.group(2)!);
    if (base == null) return null;
    return TimeControl.clock(
      baseMs: (base * 1000).round(),
      incrementMs: ((double.tryParse(match.group(3) ?? '0') ?? 0) * 1000)
          .round(),
      movesPerSession: match.group(1) == null
          ? null
          : int.tryParse(match.group(1)!),
    );
  }
}
