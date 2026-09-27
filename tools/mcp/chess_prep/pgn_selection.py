"""Search, evidence-backed reports and verified export over immutable PGN selections."""
from __future__ import annotations

import datetime
import re
from collections import defaultdict
from pathlib import Path

from .opening import fen4, parse_move_list
from .pgn_collection import CollectionStore, atomic_text, bounded, choice, digest, normalized, parse
from .tools import ToolError


def totals(rows: list) -> dict:
    wins = draws = losses = unknown = 0
    for game, match in rows:
        result = game.pgn.headers.get('Result', '*')
        if result == '1/2-1/2':
            draws += 1
        elif result in ('1-0', '0-1'):
            winner = 'white' if result == '1-0' else 'black'
            if winner == match['side']:
                wins += 1
            else:
                losses += 1
        else:
            unknown += 1
    known = wins + draws + losses
    return {'games': len(rows), 'wins': wins, 'draws': draws, 'losses': losses,
            'unknown_results': unknown, 'known_results': known,
            'score_percent': round(100 * (wins + draws / 2) / known, 2) if known else None}


def query_position(args: dict):
    import chess
    try:
        board = chess.Board(args.get('fen', chess.STARTING_FEN))
        if not board.is_valid():
            raise ValueError('Invalid query position')
        start = fen4(board)
        raw = args.get('moves', '')
        if isinstance(raw, str):
            raw = re.sub(r'\d+\.(?:\.\.)?', ' ', raw)
        moves = []
        for san in parse_move_list(raw):
            move = board.parse_san(san)
            if not board.is_legal(move):
                raise ValueError(f'Illegal move {san}')
            moves.append(move.uci())
            board.push(move)
        return start, tuple(moves), fen4(board)
    except (ValueError, TypeError) as exc:
        raise ToolError(f'Invalid moves/FEN: {exc}') from exc


def name_matches(name: str, queries: list[str], mode: str) -> bool:
    name = normalized(name)
    return any(name == normalized(q) if mode == 'exact'
               else set(normalized(q).split()) <= set(name.split()) for q in queries)


def date_bound(raw: str | None):
    if raw is None:
        return None
    try:
        return datetime.date.fromisoformat(raw.replace('.', '-'))
    except (ValueError, AttributeError) as exc:
        raise ToolError('Dates must be complete YYYY-MM-DD or YYYY.MM.DD dates.') from exc


def search(store: CollectionStore, args: dict) -> dict:
    for key in ('player', 'opponent', 'event', 'eco'):
        if key in args and not args[key].strip():
            raise ToolError(f'{key} must not be empty.')
    parent = args.get('selection_id')
    if bool(parent) == bool(args.get('collection_id')):
        raise ToolError('Provide exactly one of collection_id or selection_id to search.')
    if parent:
        previous, candidates = store.selection(parent)
        collection_id = previous['collection_id']
        perspective = previous['perspective']
    else:
        collection_id = args['collection_id']
        _, games = store.collection(collection_id)
        candidates = [(g, {'ordinal': g.ordinal, 'ply': 0, 'side': 'white'}) for g in games]
        perspective = 'white'
    color = choice(args, 'color', 'either', ('white', 'black', 'either'))
    mode = choice(args, 'match', 'position', ('position', 'prefix'))
    name_mode = choice(args, 'name_match', 'tokens', ('tokens', 'exact'))
    if (args.get('opponent') or args.get('aliases') or color != 'either') and not args.get('player'):
        raise ToolError('player is required with color, aliases or opponent.')
    if args.get('player'):
        perspective = 'matched_player'
    names = [args['player'], *args.get('aliases', [])] if args.get('player') else []
    if any(not normalized(n) for n in names + ([args['opponent']] if args.get('opponent') else [])):
        raise ToolError('Player/opponent names must contain letters or numbers.')
    result = args.get('result')
    if result is not None and result not in ('1-0', '0-1', '1/2-1/2', '*'):
        raise ToolError('result must be a PGN result: 1-0, 0-1, 1/2-1/2 or *.')
    lo, hi = date_bound(args.get('date_from')), date_bound(args.get('date_to'))
    if lo and hi and lo > hi:
        raise ToolError('date_from must not be after date_to.')
    year_lo = bounded(args, 'year_from', 1, 1, 9999)
    year_hi = bounded(args, 'year_to', 9999, 1, 9999)
    if year_lo > year_hi:
        raise ToolError('year_from must not be after year_to.')
    offset = bounded(args, 'offset', 0, 0, 1000000)
    limit = bounded(args, 'limit', 30, 1, 500)
    has_position = 'moves' in args or 'fen' in args
    start, moves, target = query_position(args) if has_position else (None, (), None)
    matches, matched_names = [], set()
    for game, old_match in candidates:
        h = game.pgn.headers
        side = old_match['side']
        if names:
            sides = [s for s in ('white', 'black') if color in ('either', s)
                     and name_matches(h.get(s.title(), ''), names, name_mode)]
            if not sides:
                continue
            if len(sides) != 1:
                raise ToolError(f'Both players match in game {game.ordinal}; specify color or exact player name.')
            side = sides[0]
        opponent = h.get('Black' if side == 'white' else 'White', '')
        if args.get('opponent') and not name_matches(opponent, [args['opponent']], name_mode):
            continue
        if result is not None and h.get('Result', '*') != result:
            continue
        if args.get('event') and args['event'].casefold() not in h.get('Event', '').casefold():
            continue
        if args.get('eco') and not h.get('ECO', '').upper().startswith(args['eco'].upper()):
            continue
        date = h.get('Date', '????.??.??')
        if 'year_from' in args or 'year_to' in args:
            if not date[:4].isdigit() or not year_lo <= int(date[:4]) <= year_hi:
                continue
        if lo or hi:
            try:
                played = datetime.date.fromisoformat(date.replace('.', '-'))
            except ValueError:
                continue
            if (lo and played < lo) or (hi and played > hi):
                continue
        ply = old_match['ply']
        if has_position:
            if mode == 'prefix':
                if game.start != start or game.moves[:len(moves)] != moves:
                    continue
                ply = len(moves)
            else:
                board = game.pgn.board()
                ply = 0 if fen4(board) == target else None
                if ply is None:
                    for n, move in enumerate(game.pgn.mainline_moves(), 1):
                        board.push(move)
                        if fen4(board) == target:
                            ply = n
                            break
                if ply is None:
                    continue
        matches.append({'ordinal': game.ordinal, 'ply': ply, 'side': side})
        if names:
            matched_names.add(h.get(side.title(), '?'))
    filters = {k: v for k, v in args.items() if k not in ('offset', 'limit')}
    selection = {'collection_id': collection_id, 'filters': filters, 'matches': matches,
                 'perspective': perspective, 'position_fen4': target if has_position else
                 previous.get('position_fen4') if parent else None}
    identifier = digest(selection)
    store.save('selections', identifier, selection)
    _, rows = store.selection(identifier)
    return {'selection_id': identifier, 'collection_id': collection_id,
            'filters': filters, 'perspective': perspective, **totals(rows),
            'matched_player_names': sorted(matched_names),
            'counting': 'Each source game once, mainline only; first position occurrence. Duplicate records retained.',
            'date_policy': 'Full-date filters exclude partial/unknown dates; year filters accept known years.',
            'items': [{**g.brief(collection_id), 'matched_ply': m['ply'], 'score_side': m['side']}
                      for g, m in rows[offset:offset + limit]],
            'next_offset': offset + limit if offset + limit < len(rows) else None}


def report(store: CollectionStore, args: dict) -> dict:
    selection, rows = store.selection(args['selection_id'])
    depth = bounded(args, 'depth', 6, 1, 16)
    limit = bounded(args, 'limit', 50, 1, 500)
    evidence_limit = bounded(args, 'evidence_limit', 3, 1, 100)
    group_by = choice(args, 'group_by', 'opponent', ('opponent', 'year', 'event', 'eco', 'time_control'))
    collection_id = selection['collection_id']

    def evidence(group):
        return {**totals(group), 'game_ids': [g.brief(collection_id)['game_id'] for g, _ in group[:evidence_limit]],
                'evidence_truncated': len(group) > evidence_limit}

    buckets, nodes, roots = defaultdict(list), defaultdict(list), defaultdict(list)
    ended = []
    for game, match in rows:
        h = game.pgn.headers
        key = {'opponent': h.get('Black' if match['side'] == 'white' else 'White', '?'),
               'year': h.get('Date', '????')[:4], 'event': h.get('Event', '?'),
               'eco': h.get('ECO', '?'), 'time_control': h.get('TimeControl', '?')}[group_by]
        buckets[key].append((game, match))
        board = game.pgn.board()
        for move in game.moves[:match['ply']]:
            board.push_uci(move)
        anchor = fen4(board)
        roots[anchor].append((game, match))
        tail = game.sans[match['ply']:match['ply'] + depth]
        if not tail:
            ended.append((game, match))
        for n in range(1, len(tail) + 1):
            nodes[(anchor, tail[:n])].append((game, match))
    branches = []
    ordered = sorted(nodes, key=lambda key: (len(key[1]), -len(nodes[key]), key))
    for anchor, line in ordered[:limit]:
        group = nodes[(anchor, line)]
        parent = roots[anchor] if len(line) == 1 else nodes[(anchor, line[:-1])]
        ordinals = {g.ordinal for g, _ in group}
        alternatives = [row for row in parent if row[0].ordinal not in ordinals]
        branches.append({'from_fen4': anchor, 'moves': list(line), 'parent_games': len(parent),
                         'share_of_parent': round(len(group) / len(parent), 4), **evidence(group),
                         'other_or_ended_games': len(alternatives),
                         'exception_game_ids': [g.brief(collection_id)['game_id'] for g, _ in alternatives[:evidence_limit]],
                         'exceptions_truncated': len(alternatives) > evidence_limit})
    groups = sorted(buckets, key=lambda key: (-len(buckets[key]), key))
    return {'selection_id': args['selection_id'], 'collection_id': collection_id,
            'filters': selection['filters'], 'perspective': selection['perspective'], **totals(rows),
            'position_fen4': selection['position_fen4'], 'group_by': group_by,
            'groups': [{'value': k, **evidence(buckets[k])} for k in groups[:limit]],
            'group_count': len(groups), 'groups_truncated': len(groups) > limit,
            'continuations': branches, 'continuation_count': len(nodes),
            'continuations_truncated': len(nodes) > limit, 'depth_plies': depth,
            'ended_at_match': evidence(ended),
            'note': 'Continuation prefixes overlap: do not sum across depths. Mainline facts, not engine judgments. '
                    'Missing time controls stay unknown; event names are not speed classifications.'}


def get_game(store: CollectionStore, args: dict) -> dict:
    import chess.pgn
    try:
        collection_id, ordinal = args['game_id'].rsplit(':', 1)
        ordinal = int(ordinal)
    except (ValueError, AttributeError) as exc:
        raise ToolError('Use a game_id returned by search/report.') from exc
    _, games = store.collection(collection_id)
    game = next((g for g in games if g.ordinal == ordinal), None)
    if game is None:
        raise ToolError('Game not found in this collection (it may have been excluded for parse errors).')
    return {**game.brief(collection_id), 'pgn': game.pgn.accept(chess.pgn.StringExporter(
        headers=True, variations=args.get('variations', True), comments=args.get('comments', True)))}


def export(store: CollectionStore, args: dict) -> dict:
    import chess.pgn
    selection, rows = store.selection(args['selection_id'])
    sort = choice(args, 'sort', 'source', ('source', 'date_asc', 'date_desc'))
    if not rows:
        raise ToolError('Selection is empty; no file written.')
    if sort != 'source':
        # Partial dates sort by known components; totally unknown years remain last.
        known = [r for r in rows if r[0].pgn.headers.get('Date', '')[:4].isdigit()]
        unknown = [r for r in rows if not r[0].pgn.headers.get('Date', '')[:4].isdigit()]
        rows = sorted(known, key=lambda r: r[0].pgn.headers.get('Date', ''), reverse=sort == 'date_desc') + unknown
    path = Path(args['path']).expanduser().absolute()
    summary, _ = store.collection(selection['collection_id'])
    if path.resolve() == Path(summary['source_path']).resolve() or store.root.resolve() in path.resolve().parents:
        raise ToolError('Choose an output outside the collection cache and different from the source.')
    if path.exists() and not args.get('overwrite', False):
        raise ToolError(f'Output exists: {path}; choose another path or explicitly set overwrite=true.')
    comments, variations = args.get('comments', True), args.get('variations', True)
    def render(game):
        return game.accept(chess.pgn.StringExporter(headers=True, comments=comments, variations=variations))
    expected = [render(g.pgn) for g, _ in rows]
    text = '\n\n'.join(expected) + '\n\n'
    reparsed, errors, count = parse(text)
    if errors or count != len(rows) or [g.identity() for g in reparsed] != [g.identity() for g, _ in rows] or [render(g.pgn) for g in reparsed] != expected:
        raise ToolError('Export round-trip verification failed; no file written.')
    try:
        atomic_text(path, text, overwrite=args.get('overwrite', False))
    except OSError as exc:
        raise ToolError(f'Could not write export: {exc}') from exc
    return {'selection_id': args['selection_id'], 'collection_id': selection['collection_id'],
            'path': str(path), 'verified': True, 'sort': sort, 'comments': comments, 'variations': variations,
            'game_ids': [g.brief(selection['collection_id'])['game_id'] for g, _ in rows],
            'perspective': selection['perspective'], **totals(rows)}
