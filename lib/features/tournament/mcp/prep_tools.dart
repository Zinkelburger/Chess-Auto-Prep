/// The *chess* half of the agent tool surface.
///
/// ## Why this is short
///
/// Identity work — directory lookup, the US Chess API, entry-list parsing,
/// account proposals — needs no engine, no opening tree, and no running app.
/// It lives in the standalone server at `tools/mcp/chess_prep/`, which an
/// agent can drive with the GUI shut.
///
/// What genuinely needs the app is chess computation: an [OpeningTree], the
/// audit walk, Stockfish, Maia and the eval cache. That is what these tools
/// expose, and nothing more. The two halves meet at the shared roster file,
/// which the standalone server writes and [TournamentSession] watches.
///
/// Nothing here lets an agent write chess data.
library;

import 'dart:convert';

import '../services/clash_service.dart';
import '../services/event_simulator.dart';
import '../services/prep_export.dart';
import '../services/tournament_session.dart';

/// One callable tool.
class PrepTool {
  final String name;
  final String description;

  /// JSON Schema for the arguments, passed straight through to MCP.
  final Map<String, dynamic> inputSchema;

  final Future<Object?> Function(Map<String, dynamic> args) handler;

  const PrepTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  Map<String, dynamic> get definition => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };
}

/// Thrown for argument problems, so the bridge can answer with a clean
/// tool-level error instead of a stack trace.
class PrepToolError implements Exception {
  final String message;
  const PrepToolError(this.message);
  @override
  String toString() => message;
}

Map<String, dynamic> _object(
  Map<String, dynamic> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
  'additionalProperties': false,
};

Map<String, dynamic> _str(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, dynamic> _int(String description) => {
  'type': 'integer',
  'description': description,
};

Map<String, dynamic> _num(String description) => {
  'type': 'number',
  'description': description,
};

Map<String, dynamic> _bool(String description) => {
  'type': 'boolean',
  'description': description,
};

/// Builds the tool registry against a live [TournamentSession].
class PrepToolRegistry {
  final TournamentSession session;

  PrepToolRegistry(this.session);

  /// Chess-only. Identity and roster editing live in the standalone server
  /// (`tools/mcp/chess_prep/`) so an agent can do that work with the app shut.
  late final List<PrepTool> tools = [
    _rosterGet,
    _pairingSimulate,
    _repertoireList,
    _prepRun,
    _prepExport,
  ];

  PrepTool? byName(String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  List<Map<String, dynamic>> get definitions =>
      tools.map((t) => t.definition).toList();

  // ── Roster ─────────────────────────────────────────────────────────────

  late final _rosterGet = PrepTool(
    name: 'roster_get',
    description:
        'The roster currently loaded in the app, with any identities resolved '
        'so far.',
    inputSchema: _object({
      'unresolved_only': _bool(
        'Return only entrants still lacking a usable account — the work list '
        'for agent-assisted resolution.',
      ),
    }),
    handler: (args) async {
      final roster = session.roster;
      if (args['unresolved_only'] == true) {
        final summary = session.resolveIdentities();
        return {
          'event_name': roster.eventName,
          'unresolved': summary.unresolvedEntries,
          'resolved_count': summary.resolved,
          'hit_rate': summary.hitRate,
        };
      }
      return roster.toMap();
    },
  );

  // ── Simulation and prep ────────────────────────────────────────────────

  late final _pairingSimulate = PrepTool(
    name: 'pairing_simulate',
    description:
        'Monte Carlo the whole event and return P(face) for every entrant, '
        'split by the color you would hold. This does not predict the pairing '
        'sheet — it samples thousands of plausible events, which is robust to '
        'exactly the withdrawals, late entries and withholds that make a '
        'specific prediction impossible. Round 1 comes out near-certain (it '
        'is a plain top-half/bottom-half split); later rounds diffuse toward '
        'the players near your rating.',
    inputSchema: _object({
      'trials': _int('Simulated events (default 2000).'),
      'seed': _int('RNG seed, for reproducibility.'),
      'draw_rate': _num('Draw rate between equal players (default 0.30).'),
    }),
    handler: (args) async {
      if (session.roster.me == null) {
        throw const PrepToolError(
          'No entrant is marked as you. Call roster_update with is_me first — '
          'pairing probabilities need a reference point.',
        );
      }

      final result = session.simulate(
        config: SimulationConfig(
          trials: (args['trials'] as num?)?.toInt() ?? 2000,
          seed: (args['seed'] as num?)?.toInt() ?? 20260806,
          drawRate: (args['draw_rate'] as num?)?.toDouble() ?? 0.30,
        ),
      );

      final byId = {for (final e in session.roster.entries) e.id: e};
      return {
        ...result.toMap(),
        'opponents': result.opponents
            .map(
              (o) => {
                ...o.toMap(),
                'name': byId[o.playerId]?.name,
                'rating': byId[o.playerId]?.rating,
                'has_account': byId[o.playerId]?.identity?.hasAccount ?? false,
              },
            )
            .toList(),
      };
    },
  );

  late final _repertoireList = PrepTool(
    name: 'repertoire_list',
    description:
        'PGN repertoire files available to clash against. Pass one of these '
        'paths as white_repertoire_path / black_repertoire_path to prep_run.',
    inputSchema: _object(const {}),
    handler: (args) async => {
      'repertoires': await TournamentSession.availableRepertoires(),
    },
  );

  late final _prepRun = PrepTool(
    name: 'prep_run',
    description:
        'Run the full pipeline: simulate the event, download each likely '
        'opponent\'s games, clash them against your repertoire, and pool the '
        'gaps into a ranked study list. Positions are scored by '
        'P(pair) × P(reach) × P(they play it), so the top of the list is what '
        'you are most likely to actually face. This is the expensive call — '
        'it downloads games per opponent — so it skips anyone below '
        'min_pairing_prob. Requires resolved identities.',
    inputSchema: _object({
      'white_repertoire_path': _str('PGN for your White repertoire.'),
      'black_repertoire_path': _str('PGN for your Black repertoire.'),
      'min_pairing_prob': _num(
        'Skip opponents below this P(face) (default 0.05).',
      ),
      'max_opponents': _int('Hard cap on opponents clashed.'),
      'max_games': _int('Games to pull per opponent (default 300).'),
      'months_back': _int(
        'Only use games from the last N months (default 24).',
      ),
      'min_move_share': _num(
        'Ignore opponent moves played less often than this (default 0.05).',
      ),
      'max_ply': _int('Plies of repertoire to walk (default 24).'),
    }),
    handler: (args) async {
      final white = args['white_repertoire_path'] as String?;
      final black = args['black_repertoire_path'] as String?;
      if ((white == null || white.isEmpty) &&
          (black == null || black.isEmpty)) {
        throw const PrepToolError(
          'Supply white_repertoire_path and/or black_repertoire_path. '
          'Call repertoire_list to see what is available.',
        );
      }
      if (session.roster.me == null) {
        throw const PrepToolError(
          'No entrant is marked as you. Call roster_update with is_me first.',
        );
      }
      if (session.isPreparing) {
        throw const PrepToolError('A prep run is already in progress.');
      }

      final report = await session.prepare(
        whiteRepertoirePath: white?.isEmpty == true ? null : white,
        blackRepertoirePath: black?.isEmpty == true ? null : black,
        minPairingProb: (args['min_pairing_prob'] as num?)?.toDouble() ?? 0.05,
        maxOpponents: (args['max_opponents'] as num?)?.toInt(),
        clashConfig: ClashConfig(
          maxGames: (args['max_games'] as num?)?.toInt() ?? 300,
          monthsBack: (args['months_back'] as num?)?.toInt() ?? 24,
          minMoveShare: (args['min_move_share'] as num?)?.toDouble() ?? 0.05,
          maxPly: (args['max_ply'] as num?)?.toInt() ?? 24,
        ),
      );

      // The full report can be very large; return the actionable head and
      // let prep_export produce the rest.
      return {
        'event_name': report.eventName,
        'elapsed_ms': report.elapsed.inMilliseconds,
        'position_count': report.positions.length,
        'opponents_clashed': report.clashReports.length,
        'top_positions': report.positions
            .take(20)
            .map((p) => p.toMap())
            .toList(),
        'covers_80_percent_in': report.topByCoverage(0.8).length,
        'warnings': report.warnings,
      };
    },
  );

  late final _prepExport = PrepTool(
    name: 'prep_export',
    description:
        'Render the last prep run. "pgn" gives one chapter per line for the '
        'Study screen, "briefing" a plain-text summary. For the roster itself '
        'as CSV, use roster_export on the standalone prep server.',
    inputSchema: _object({
      'format': {
        'type': 'string',
        'enum': ['pgn', 'briefing'],
        'description': 'What to render (default "briefing").',
      },
      'limit': _int('Max positions to include.'),
      'player_id': _str(
        'Restrict a PGN export to one opponent — the focused drill for a '
        'pairing that has actually been posted.',
      ),
    }),
    handler: (args) async {
      final format = (args['format'] as String?) ?? 'briefing';
      final limit = (args['limit'] as num?)?.toInt();

      final report = session.report;
      if (report == null) {
        throw const PrepToolError(
          'No prep run has completed yet. Call prep_run first.',
        );
      }

      final playerId = args['player_id'] as String?;
      final content = switch (format) {
        'pgn' =>
          playerId != null && playerId.isNotEmpty
              ? PrepExporter.opponentPgn(report, playerId, limit: limit)
              : PrepExporter.toPgn(report, limit: limit),
        'briefing' => PrepExporter.toBriefing(report, limit: limit ?? 10),
        _ => throw PrepToolError('Unknown format "$format".'),
      };

      return {'format': format, 'content': content};
    },
  );

  /// Dispatch a call by name, returning a JSON-encodable result.
  Future<Object?> call(String name, Map<String, dynamic> args) async {
    final tool = byName(name);
    if (tool == null) throw PrepToolError('Unknown tool "$name".');
    return tool.handler(args);
  }

  /// Dispatch and encode, mapping failures onto a structured error payload.
  Future<Map<String, dynamic>> callEncoded(
    String name,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await call(name, args);
      return {'ok': true, 'result': result};
    } on PrepToolError catch (e) {
      return {'ok': false, 'error': e.message};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// Pretty JSON, which is what the MCP shim hands back as tool text.
  static String encode(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}
