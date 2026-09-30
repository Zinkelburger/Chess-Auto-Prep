/// Headless driver for the Engine tournament mode.
///
/// Runs the same code the app runs — `TournamentGameRunner` for each game,
/// `FileTournaments` for `tournament.json` + `games.pgn`, the
/// `EngineSupervisor` for every engine process — without a Flutter engine,
/// and writes into the same `Documents/engine_tournaments/` tree, so a match
/// started here shows up in the app's Engine tournament mode.
///
///   dart run tools/run_engine_tournament.dart \
///     --name "Stockfish self-match" \
///     --fen "3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1" \
///     --games 10 --movetime 2000
///
/// Engines default to the bundled Stockfish playing itself. Add
/// `--engine "Name=/path/to/binary"` (repeatable) for anything else.
/// `tools/mcp/chess_prep/engine_tournament.py` drives this file; its
/// arguments, the `TOURNAMENT {json}` handshake line and the `--show` /
/// `--verify` JSON are that module's contract.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/stockfish_install.dart';
import 'package:chess_auto_prep/engines/tournament_launch.dart';
import 'package:chess_auto_prep/engines/uci_process.dart' show EngineTranscript;
import 'package:chess_auto_prep/features/tournaments/engine_check.dart';
import 'package:chess_auto_prep/features/tournaments/game_runner.dart';
import 'package:chess_auto_prep/features/tournaments/schedule.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  final engines = EngineSupervisor();
  try {
    exitCode = await _run(args, engines);
  } finally {
    await engines.dispose();
  }
}

Future<int> _run(_Args args, EngineSupervisor engines) async {
  if (args.help) {
    stdout.writeln(_usage);
    return 0;
  }
  final documents = _documentsDirectory();
  final root = Directory(
    args.root ?? p.join(documents, 'engine_tournaments'),
  ).absolute;
  // The app's support folder only beside the app's own documents: its
  // recovery records name paths there. Elsewhere the run keeps its own.
  final support = Directory(
    args.support ??
        (p.equals(root.parent.path, documents)
            ? _appSupportDirectory()
            : p.join(root.path, '.support')),
  );
  // The app's launcher. The bundled Stockfish is installed from the
  // repository's assets, so it is found when run from the repository root.
  final stockfish = StockfishInstall(
    supportDirectory: support,
    readAsset: (asset) async {
      final file = File(asset);
      return await file.exists() ? await file.readAsBytes() : null;
    },
  );
  Future<EngineStart> launch(
    TournamentEngine spec,
    EngineTranscript transcript,
  ) => launchTournamentEngine(
    spec,
    transcript,
    stockfish: stockfish,
    engines: engines,
  );

  // `--verify <path>` vets a binary before the MCP tools write it into
  // engines.json, and runs nothing else.
  if (args.verify case final path?) {
    final report = await _verify(
      launch,
      TournamentEngine({'name': p.basename(path), 'executablePath': path}),
    );
    stdout.writeln(jsonEncode({'path': path, ...report}));
    return report['ok'] == true ? 0 : 3;
  }

  final store = FileTournaments(
    root: root,
    support: support,
    documents: PgnFileStore(documents: root.parent, support: support),
  );

  // `--show <id>` prints one saved tournament as JSON, so the MCP tools
  // quote the standings the app computes rather than their own.
  if (args.show case final id?) {
    final listed = await store.list();
    final found = switch (listed) {
      TournamentSaved(:final value) =>
        value.where((t) => t.id == id).firstOrNull,
      TournamentFailed() => null,
    };
    if (found == null) {
      stdout.writeln(
        jsonEncode({
          'ok': false,
          'error': switch (listed) {
            TournamentFailed(:final message) => message,
            _ => 'No tournament "$id" in ${root.path}',
          },
        }),
      );
      return 4;
    }
    stdout.writeln(jsonEncode(_showPayload(found, store)));
    return 0;
  }

  final config = TournamentConfig({
    'name': args.name,
    'startFen': args.fen ?? Fen.initial.value,
    'openingLabel': args.opening,
    'engines': [for (final e in _engines(args)) e.json],
    'timeControl': args.timeControl,
    'gamesPerPairing': args.games,
    'concurrency': args.concurrency,
    'alternateColors': true,
    'adjudication': <String, Object?>{},
  });
  if (config.problem case final problem?) {
    stderr.writeln(problem);
    return 2;
  }

  stdout.writeln('Verifying ${config.engines.length} engine(s)…');
  final checked = <String>{};
  for (final spec in config.engines) {
    if (!checked.add(spec.executable ?? '')) continue;
    final report = await _verify(launch, spec);
    stdout.writeln(
      '  ${report['ok'] == true ? 'ok' : 'FAIL'}  ${spec.name}: '
      '${report['message']}',
    );
    if (report['ok'] != true) return 3;
  }

  final now = DateTime.now().toUtc();
  final created = await store.create(
    Tournament({
      'version': 1,
      'id': 'match-${now.microsecondsSinceEpoch}',
      'createdAt': now.toIso8601String(),
      'status': 'pending',
      'config': config.json,
      'games': <Object>[],
    }),
  );
  if (created case TournamentFailed(:final message)) {
    stderr.writeln('Could not create the tournament: $message');
    return 1;
  }
  final tournament = (created as TournamentSaved<Tournament>).value;
  final directory = p.join(root.path, tournament.id);

  // One machine-readable line as soon as the directory exists, before any
  // engine thinks: a detached caller has no other way to learn the id.
  stdout.writeln(
    'TOURNAMENT ${jsonEncode({'id': tournament.id, 'directory': directory, 'pgn': store.games(tournament.id).path, 'metadata': p.join(directory, 'tournament.json'), 'totalGames': config.gameCount, 'timeControl': config.timeLabel, 'startFen': config.root.value})}',
  );
  stdout
    ..writeln('')
    ..writeln('Tournament "${config.name}" → $directory')
    ..writeln('  position    ${config.root.value}')
    ..writeln('  control     ${config.timeLabel}')
    ..writeln('  games       ${config.gameCount}')
    ..writeln('  concurrency ${config.concurrency}')
    ..writeln('');

  final match = _Match(store, tournament, TournamentSchedule(config, launch));
  // Ctrl-C (and the MCP tournament_stop) finish the games in flight, so the
  // PGN stays whole. The listener is cancelled below: a live signal
  // subscription keeps the VM alive.
  final interrupts = ProcessSignal.sigint.watch().listen((_) {
    stdout.writeln('\nStopping after the games in flight…');
    match.stopping = true;
  });
  final problem = await match.play();
  await interrupts.cancel();

  final finished = match.saved;
  stdout
    ..writeln('')
    ..writeln(_renderCrosstable(finished))
    ..writeln('')
    ..writeln('Status: ${finished.status}')
    ..writeln('PGN:    ${store.games(finished.id).path}')
    ..writeln('Meta:   ${p.join(directory, 'tournament.json')}');
  if (problem != null) stderr.writeln('Error: $problem');
  return problem == null ? 0 : 1;
}

/// The app's saving in `TournamentRun`, without the retry UI: a failed
/// checkpoint stops the run and is reported, and the saved files keep every
/// game committed before it.
final class _Match {
  _Match(this.store, this.saved, this.games);
  final FileTournaments store;
  final TournamentSchedule games;
  Tournament saved;
  String? _pgn;
  bool stopping = false;
  String? _problem;

  Future<String?> play() async {
    final total = saved.config.gameCount;
    await games.play(
      stopping: () => stopping,
      afterGame: (pairing, game) {
        stdout.writeln(
          '  game ${pairing.index + 1}/$total  '
          '${game.record.whiteName} - ${game.record.blackName}  '
          '${game.record.result}  ${game.record.termination}',
        );
        return _checkpoint();
      },
    );
    if (_problem == null) {
      await _persist(
        saved.changed({
          'status': stopping ? 'stopped' : 'completed',
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        _pgn ?? '',
      );
    }
    return _problem;
  }

  Future<void> _checkpoint() async {
    if (_problem != null) return;
    final (:records, :pgn) = games.finished;
    await _persist(saved.changed({'status': 'running', 'games': records}), pgn);
  }

  Future<void> _persist(Tournament after, String pgn) async {
    final result = await store.save(saved, after, pgn, expectedPgn: _pgn);
    switch (result) {
      case TournamentSaved(:final value):
        saved = value;
        _pgn = pgn;
      case TournamentFailed(:final message):
        _problem = 'The tournament was not saved: $message';
        stopping = true;
    }
  }
}

/// The engine check the app runs before registering an engine, as the
/// JSON `engine_tournament.py` reads.
Future<Map<String, Object?>> _verify(
  TournamentLauncher launch,
  TournamentEngine spec,
) async => switch (await checkTournamentEngine(launch, spec)) {
  EngineVerified(:final name, :final move) => {
    'ok': true,
    'message': '$name: UCI ready; played $move.',
    'name': name,
    'sampleMove': move,
  },
  EngineRejected(:final reason, :final output) => {
    'ok': false,
    'message': reason,
    'transcript': output,
  },
};

List<TournamentEngine> _engines(_Args args) {
  if (args.engines.isEmpty) {
    return [
      for (final name in ['Stockfish A', 'Stockfish B'])
        TournamentEngine({
          ...TournamentEngine.bundled(name).json,
          if (args.stockfish != null) 'executablePath': args.stockfish,
        }),
    ];
  }
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return [
    for (final (i, entry) in args.engines.indexed)
      TournamentEngine({
        'id': 'engine-$stamp-$i',
        'name': entry.contains('=')
            ? entry.substring(0, entry.indexOf('='))
            : p.basename(entry),
        'executablePath': entry.contains('=')
            ? entry.substring(entry.indexOf('=') + 1)
            : entry,
        'hashMb': 128,
        'threads': 1,
        'ponder': false,
      }),
  ];
}

/// Everything `--show` reports about one tournament.
Map<String, Object?> _showPayload(Tournament t, FileTournaments store) {
  final config = t.config;
  final standings = t.standings;
  final byName = {for (final row in standings) row.seat: row.name};
  return {
    'ok': true,
    'id': t.id,
    'name': config.name,
    'status': t.status,
    'createdAt': t.json['createdAt'],
    'finishedAt': t.json['finishedAt'],
    'error': t.error,
    'startFen': config.root.value,
    'opening': config.json['openingLabel'] ?? '',
    'timeControl': config.timeLabel,
    'format': config.json['format'] ?? 'roundRobin',
    'concurrency': config.concurrency,
    'gamesPlayed': t.games.length,
    'gamesTotal': config.gameCount,
    'directory': p.dirname(store.games(t.id).path),
    'pgn': store.games(t.id).path,
    'engines': [for (final e in config.engines) e.name],
    'standings': [
      for (final (i, row) in standings.indexed)
        {
          'rank': i + 1,
          'engineIndex': row.seat,
          'name': row.name,
          'points': row.score.points,
          'played': row.score.played,
          'wins': row.score.wins,
          'draws': row.score.draws,
          'losses': row.score.losses,
          'score': row.score.label,
          'scorePercent': _percent(row.score.points, row.score.played),
          'drawPercent': _percent(row.score.draws, row.score.played),
          'sonnebornBerger': row.sonnebornBerger,
          'eloDiff': row.score.elo,
          'eloMargin': row.score.margin,
          'likelihoodOfSuperiority': row.score.superiority * 100,
        },
    ],
    'headToHead': {
      for (final row in standings)
        row.name: {
          for (final (opponent, cell) in row.opponents.indexed)
            if (opponent != row.seat && cell.played > 0)
              byName[opponent]!: {
                'points': cell.points,
                'played': cell.played,
                'results': _results(t, row.seat, opponent),
              },
        },
    },
    'games': [
      for (final game in t.games)
        {
          'number': game.index + 1,
          'round': game.json['round'],
          'white': game.whiteName,
          'black': game.blackName,
          'result': game.result,
          'termination': game.termination,
          'detail': game.detail,
          'plies': game.json['plies'],
          'seconds': ((game.json['durationMs'] as num?) ?? 0) / 1000,
        },
    ],
    'text': _renderCrosstable(t),
  };
}

double _percent(num part, int whole) => whole == 0 ? 0 : part / whole * 100;

/// `1`, `=` and `0` per game from [seat]'s side, in schedule order.
String _results(Tournament t, int seat, int opponent) => [
  for (final game in t.games)
    if ({game.white, game.black}.containsAll([seat, opponent]))
      switch ((game.result, game.white == seat)) {
        ('1/2-1/2', _) => '=',
        ('1-0', true) || ('0-1', false) => '1',
        ('1-0', false) || ('0-1', true) => '0',
        _ => '*',
      },
].join();

String _renderCrosstable(Tournament t) {
  final standings = t.standings;
  final buffer = StringBuffer()
    ..writeln('Crosstable')
    ..writeln('=' * 78);
  final width = standings.fold(
    6,
    (a, r) => r.name.length > a ? r.name.length : a,
  );
  buffer.writeln(
    '${'#'.padLeft(2)}  ${'Engine'.padRight(width)}  '
    '${'Score'.padLeft(8)}  ${'W'.padLeft(3)} ${'D'.padLeft(3)} ${'L'.padLeft(3)}  '
    '${'Draw%'.padLeft(6)}  ${'Elo'.padLeft(14)}  ${'LOS'.padLeft(6)}  SB',
  );
  for (final (i, row) in standings.indexed) {
    final s = row.score;
    final elo = s.elo == null
        ? '—'
        : '${s.elo! >= 0 ? '+' : ''}${s.elo!.toStringAsFixed(0)}'
              '${s.margin == null ? '' : ' ±${s.margin!.toStringAsFixed(0)}'}';
    buffer.writeln(
      '${'${i + 1}'.padLeft(2)}  ${row.name.padRight(width)}  '
      '${s.label.padLeft(8)}  ${'${s.wins}'.padLeft(3)} '
      '${'${s.draws}'.padLeft(3)} ${'${s.losses}'.padLeft(3)}  '
      '${_percent(s.draws, s.played).toStringAsFixed(0).padLeft(5)}%  '
      '${elo.padLeft(14)}  '
      '${(s.superiority * 100).toStringAsFixed(1).padLeft(5)}%  '
      '${row.sonnebornBerger.toStringAsFixed(2)}',
    );
  }
  buffer.writeln('');
  for (final row in standings) {
    for (final (opponent, cell) in row.opponents.indexed) {
      if (opponent == row.seat || cell.played == 0) continue;
      buffer.writeln(
        '  ${row.name} vs ${t.config.engines[opponent].name}: '
        '${cell.label}  ${_results(t, row.seat, opponent)}',
      );
    }
  }
  return buffer.toString();
}

String _documentsDirectory() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  final xdg = Platform.environment['XDG_DOCUMENTS_DIR'];
  return xdg != null && xdg.isNotEmpty ? xdg : p.join(home, 'Documents');
}

/// Where path_provider puts the app's support folder (the Python tools'
/// `master_db_path` mirrors the same rule).
String _appSupportDirectory() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
  final base = Platform.isMacOS
      ? p.join(home, 'Library', 'Application Support')
      : Platform.isWindows
      ? env['APPDATA'] ?? p.join(home, 'AppData', 'Roaming')
      : (env['XDG_DATA_HOME']?.isNotEmpty ?? false)
      ? env['XDG_DATA_HOME']!
      : p.join(home, '.local', 'share');
  return p.join(base, 'com.example.chess_auto_prep');
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
  --stockfish <path>   Use this binary instead of the bundled Stockfish
  --root <dir>         Tournaments directory (default
                       ~/Documents/engine_tournaments)
  --support <dir>      Support folder for recovery records (default: the
                       app's, or <root>/.support for another --root)
  --verify <path>      Check one binary is a working UCI engine and print the
                       report as JSON; runs nothing else
  --show <id>          Print a saved tournament (crosstable, standings, games)
                       as JSON and exit
  -h, --help
''';

final class _Args {
  String name = 'Engine match';
  String? fen;
  String opening = '';
  int games = 10;
  int concurrency = 1;
  Map<String, Object?> timeControl = {'kind': 'movetime', 'movetimeMs': 2000};
  final engines = <String>[];
  String? stockfish;
  String? root;
  String? support;
  String? verify;
  String? show;
  bool help = false;

  static _Args parse(List<String> argv) {
    final args = _Args();
    for (var i = 0; i < argv.length; i++) {
      String next() => i + 1 < argv.length ? argv[++i] : '';
      switch (argv[i]) {
        case '--name':
          args.name = next();
        case '--fen':
          args.fen = next();
        case '--opening':
          args.opening = next();
        case '--games':
          args.games = int.tryParse(next()) ?? args.games;
        case '--concurrency':
          args.concurrency = int.tryParse(next()) ?? args.concurrency;
        case '--movetime':
          args.timeControl = {
            'kind': 'movetime',
            'movetimeMs': int.tryParse(next()) ?? 2000,
          };
        case '--depth':
          args.timeControl = {
            'kind': 'fixedDepth',
            'depth': int.tryParse(next()) ?? 12,
          };
        case '--tc':
          args.timeControl = _parseTc(next()) ?? args.timeControl;
        case '--engine':
          args.engines.add(next());
        case '--stockfish':
          args.stockfish = next();
        case '--root':
          args.root = next();
        case '--support':
          args.support = next();
        case '--verify':
          args.verify = next();
        case '--show':
          args.show = next();
        case '-h' || '--help':
          args.help = true;
      }
    }
    return args;
  }

  /// `60+0.6` / `40/60+0.6` / `120`, in seconds — cutechess's spelling.
  static Map<String, Object?>? _parseTc(String text) {
    final match = RegExp(
      r'^(?:(\d+)/)?([\d.]+)(?:\+([\d.]+))?$',
    ).firstMatch(text.trim());
    final base = double.tryParse(match?.group(2) ?? '');
    if (match == null || base == null) return null;
    return {
      'kind': 'incremental',
      'baseMs': (base * 1000).round(),
      'incrementMs': ((double.tryParse(match.group(3) ?? '0') ?? 0) * 1000)
          .round(),
      if (int.tryParse(match.group(1) ?? '') case final period? when period > 0)
        'movesPerSession': period,
    };
  }
}
