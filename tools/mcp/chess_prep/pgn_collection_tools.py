"""MCP contracts for game collections (distinct from repertoire opening graphs)."""
from .opening import _require_chess
from .pgn_collection import CollectionStore
from .pgn_selection import export, get_game, report, search
from .tools import ToolError, _b, _i, _obj, _s


def register_collection_tools(registry):
    store = CollectionStore()
    registry.add_close_callback(store.cache.clear)
    collection = _s('Immutable collection_id from pgn_collection_open.')
    selection = _s('Persisted selection_id from pgn_games_search; report and export use this exact set.')
    paging = {'offset': _i('Zero-based result offset (default 0). Does not change the selection.'),
              'limit': _i('Page size, 1–500. Does not truncate total counts or exports.')}
    annotations = {'comments': _b('Preserve comments and NAGs (default true).'),
                   'variations': _b('Preserve annotation variations (default true). Search always uses mainlines.')}

    def add(name, description, properties, required, handler):
        def call(args):
            extra = set(args) - set(properties)
            if extra:
                raise ToolError('Unknown arguments: ' + ', '.join(sorted(extra)))
            missing = [key for key in required if key not in args]
            if missing:
                raise ToolError('Required arguments: ' + ', '.join(missing))
            for key, value in args.items():
                kind = properties[key]['type']
                valid = {'string': isinstance(value, str), 'integer': type(value) is int,
                         'boolean': type(value) is bool, 'array': isinstance(value, list)}
                if not valid[kind] or (kind == 'array' and any(not isinstance(v, str) for v in value)):
                    raise ToolError(f'{key} must be {kind}.')
            _require_chess()
            try:
                return handler(args)
            except (OSError, UnicodeError) as exc:
                raise ToolError(str(exc)) from exc
        registry._add(name, description, _obj(properties, required), call)

    add('pgn_collection_open',
        'Open a local PGN or ZIP of games (up to 32 MiB), without modifying the source or app databases. '
        'Creates a persistent content-addressed snapshot under CHESS_PREP_PGN_DIR or '
        '~/.local/share/chess-prep/pgn-collections. Returns collection_id, player spellings/counts, dates, '
        'encoding, parse errors and duplicate candidates (retained). Multiple PGN ZIP members require member. '
        'Reopen changed sources; old selections continue to refer to their immutable snapshot. '
        'Use pgn_games_search next; for courses/repertoires use pgn_open instead.',
        {'path': _s('Path to local .pgn or .zip.'),
         'member': _s('Exact PGN ZIP member name; required if more than one.'),
         'encoding': _s('Optional explicit text encoding. Default: UTF-8, then heuristic CP1252/Latin-1.'),
         **paging}, ['path'], store.open)

    add('pgn_games_search',
        'Find actual played games in a PGN collection or narrow a previous selection. Persists the complete '
        'matching game set and returns selection_id, full W/D/L/unknown totals, paginated headers, '
        'matching plies and player spellings. Match position (default) merges transpositions using piece '
        'placement, turn, castling rights and legal en passant; prefix requires the exact starting position '
        'and move order. Mainlines only, each source record once at its first matching position; duplicates '
        'are retained. Results are from the matched player perspective, otherwise White (or inherited '
        'from a parent selection). Search totals never depend on pagination. Use report/get/export next.',
        {'collection_id': collection, 'selection_id': selection,
         'player': _s('Player name; default matches complete name tokens in any order (Karpov matches Karpov, Anatoly).'),
         'aliases': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Explicit alternative player spellings; no fuzzy identity guesses.'},
         'name_match': _s('tokens (default) or exact, after case/punctuation normalization. Applies to opponent too.'),
         'color': _s('white, black or either (default); requires player.'),
         'opponent': _s('Opponent name; requires player.'),
         'result': _s('PGN result: 1-0, 0-1, 1/2-1/2 or *. Independent of score perspective.'),
         'event': _s('Case-insensitive event substring; does not infer speed.'),
         'eco': _s('ECO tag prefix; tags may be absent/inaccurate, use moves for verified openings.'),
         'year_from': _i('Inclusive earliest known year; excludes unknown years.'),
         'year_to': _i('Inclusive latest known year; accepts dates with unknown month/day.'),
         'date_from': _s('Inclusive YYYY-MM-DD; excludes partial/unknown dates.'),
         'date_to': _s('Inclusive YYYY-MM-DD; excludes partial/unknown dates.'),
         'moves': _s('SAN movetext, e.g. 1.e4 c6 2.d4 d5 3.Nd2 dxe4 4.Nxe4 Bf5.'),
         'fen': _s('Starting FEN for moves, or target FEN alone. Default standard start.'),
         'match': _s('position (default) or prefix. Without moves/fen, preserve parent match ply or start at ply 0.'),
         **paging}, [], lambda a: search(store, a))

    add('pgn_selection_report',
        'Report the exact saved selection: W/D/L, unknown results, score percentage over known results, '
        'metadata groups and continuation prefixes after each matched ply. Includes supporting game IDs '
        'and exceptions to each continuation, bounded evidence lists with explicit truncation. '
        'Counts distinct source records, never analysis variations or repeated position visits. '
        'Continuation depths overlap; do not sum across them. No engine or speed guesses.',
        {'selection_id': selection, 'depth': _i('Continuation depth in plies, 1–16 (default 6).'),
         'group_by': _s('opponent (default), year, event, eco or time_control.'),
         'limit': _i('Maximum groups and continuation nodes, 1–500 (default 50); totals stay complete.'),
         'evidence_limit': _i('Game IDs per evidence/exception list, 1–100 (default 3).')},
        ['selection_id'], lambda a: report(store, a))

    add('pgn_game_get', 'One complete game by game_id from search/report, with original headers and '
        'PGN annotations by default. Does not reconstruct a game from a chapter label or model memory.',
        {'game_id': _s('Exact game_id from search/report.'), **annotations},
        ['game_id'], lambda a: get_game(store, a))

    add('pgn_selection_export',
        'Write the complete saved selection to a UTF-8 PGN. Reparse before atomic publication and verify '
        'headers, mainlines, count and requested annotations. Returns verified=true, game IDs and matching '
        'totals. Existing output requires overwrite=true. Never overwrites the source or collection cache. '
        'No app launch or database writes. Partial dates sort lexically by known components; unknown years last.',
        {'selection_id': selection, 'path': _s('Output PGN path.'),
         'sort': _s('source (default), date_asc or date_desc.'),
         'overwrite': _b('Explicitly replace existing output (default false).'), **annotations},
        ['selection_id', 'path'], lambda a: export(store, a))
