"""Immutable, content-addressed PGN snapshots; never writes the source or app DBs."""
from __future__ import annotations

import codecs
import hashlib
import io
import json
import os
import re
import tempfile
import unicodedata
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .opening import _require_chess, fen4
from .tools import ToolError

VERSION = 1
MAX_BYTES = 32 * 1024 * 1024


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def bounded(args: dict, key: str, default: int, low: int, high: int) -> int:
    value = args.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ToolError(f"{key} must be an integer from {low} to {high}.")
    return value


def choice(args: dict, key: str, default: str, options: tuple[str, ...]) -> str:
    value = args.get(key, default)
    if value not in options:
        raise ToolError(f"{key} must be one of {', '.join(options)}.")
    return value


def normalized(text: str) -> str:
    return ' '.join(re.findall(r'\w+', unicodedata.normalize('NFKC', text).casefold()))


def atomic_text(path: Path, text: str, overwrite: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.pgn-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(text)
        if overwrite:
            os.replace(name, path)
        else:
            # link is an atomic create-if-absent; a concurrent export cannot be clobbered.
            os.link(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


@dataclass
class Game:
    ordinal: int
    pgn: Any
    moves: tuple[str, ...]
    sans: tuple[str, ...]
    start: str

    def identity(self) -> dict:
        return {'headers': dict(self.pgn.headers), 'start': self.start, 'moves': self.moves}

    def brief(self, collection_id: str) -> dict:
        return {'game_id': f'{collection_id}:{self.ordinal}', 'ordinal': self.ordinal,
                'headers': dict(self.pgn.headers), 'plies': len(self.moves)}


def parse(text: str) -> tuple[list[Game], list[dict], int]:
    _require_chess()
    import chess.pgn

    class QuietBuilder(chess.pgn.GameBuilder):
        def handle_error(self, error):
            self.game.errors.append(error)

    games, errors, ordinal = [], [], 0
    stream = io.StringIO(text)
    while True:
        try:
            game = chess.pgn.read_game(stream, Visitor=QuietBuilder)
        except (ValueError, IndexError) as exc:
            raise ToolError(f'PGN parsing stopped before game {ordinal + 1}: {exc}') from exc
        if game is None:
            break
        ordinal += 1
        try:
            if game.errors:
                raise ValueError('; '.join(map(str, game.errors)))
            board = game.board()
            if board.uci_variant != 'chess' or board.chess960:
                raise ValueError('Only standard chess is supported by this collection index.')
            if not board.is_valid():
                raise ValueError('Invalid starting position')
            start, moves, sans = fen4(board), [], []
            for move in game.mainline_moves():
                if not board.is_legal(move):
                    raise ValueError(f'Illegal mainline move {move}')
                moves.append(move.uci())
                sans.append(board.san(move))
                board.push(move)
            games.append(Game(ordinal, game, tuple(moves), tuple(sans), start))
        except ValueError as exc:
            errors.append({'ordinal': ordinal, 'error': str(exc), 'headers': dict(game.headers)})
    return games, errors, ordinal


def read_source(path: Path, member: str | None, encoding: str | None) -> tuple[str, dict]:
    if not path.is_file():
        raise ToolError(f'PGN/ZIP not found: {path}')
    if path.stat().st_size > MAX_BYTES:
        raise ToolError('Collection input exceeds 32 MiB; split the file first.')
    raw = path.read_bytes()
    source_hash = hashlib.sha256(raw).hexdigest()
    members = []
    if zipfile.is_zipfile(io.BytesIO(raw)):
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = [x for x in archive.infolist() if not x.is_dir() and x.filename.lower().endswith('.pgn')]
            members = [{'name': x.filename, 'bytes': x.file_size} for x in entries]
            if member is None and len(entries) != 1:
                raise ToolError('Choose member from the PGNs in this ZIP: ' + json.dumps(members))
            found = [x for x in entries if member is None or x.filename == member]
            if len(found) != 1:
                raise ToolError('ZIP member is missing or ambiguous: ' + json.dumps(members))
            info = found[0]
            member = info.filename
            if info.file_size > MAX_BYTES:
                raise ToolError('Uncompressed PGN exceeds 32 MiB; split the file first.')
            # Read in memory; ZIP names are never used as filesystem paths.
            with archive.open(info) as stream:
                raw = stream.read(MAX_BYTES + 1)
    elif member is not None:
        raise ToolError('member is only valid for ZIP input.')
    if len(raw) > MAX_BYTES:
        raise ToolError('Uncompressed PGN exceeds 32 MiB.')
    inferred = encoding is None
    if encoding:
        try:
            encoding = codecs.lookup(encoding).name
            text = raw.decode(encoding)
        except (LookupError, UnicodeError) as exc:
            raise ToolError(f'Cannot decode with {encoding}: {exc}') from exc
    else:
        for encoding in ('utf-8-sig', 'cp1252', 'latin-1'):
            try:
                text = raw.decode(encoding)
                break
            except UnicodeDecodeError:
                pass
    return text, {'source_path': str(path), 'source_sha256': source_hash,
                  'member': member, 'members': members, 'encoding': encoding,
                  'encoding_inferred': inferred,
                  'encoding_note': 'Non-UTF-8 detection is heuristic; pass encoding to override.'
                  if inferred and encoding != 'utf-8-sig' else None}


class CollectionStore:
    def __init__(self, root: Path | None = None):
        self.root = root or Path(os.environ.get('CHESS_PREP_PGN_DIR',
                                                '~/.local/share/chess-prep/pgn-collections')).expanduser()
        self.cache: dict[str, tuple[dict, list[Game]]] = {}

    def path(self, kind: str, identifier: str) -> Path:
        if not isinstance(identifier, str) or not re.fullmatch(r'[0-9a-f]{64}', identifier):
            raise ToolError(f'Invalid {kind} ID; use the ID returned by the tool.')
        return self.root / kind / f'{identifier}.json'

    def save(self, kind: str, identifier: str, value: dict):
        atomic_text(self.path(kind, identifier), json.dumps(value, ensure_ascii=True))

    def read(self, kind: str, identifier: str) -> dict:
        try:
            return json.loads(self.path(kind, identifier).read_text(encoding='utf-8'))
        except (OSError, ValueError) as exc:
            raise ToolError(f'{kind} snapshot unavailable; reopen/search the collection: {exc}') from exc

    def open(self, args: dict) -> dict:
        offset = bounded(args, 'offset', 0, 0, 1000000)
        limit = bounded(args, 'limit', 100, 1, 500)
        path = Path(args['path']).expanduser().resolve()
        try:
            text, source = read_source(path, args.get('member'), args.get('encoding'))
        except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as exc:
            raise ToolError(f'Cannot read ZIP collection: {exc}') from exc
        _require_chess()
        import chess
        identity = {'version': VERSION, 'parser': chess.__version__,
                    'source_path': source['source_path'], 'source_sha256': source['source_sha256'],
                    'member': source['member'], 'encoding': source['encoding'],
                    'text_sha256': hashlib.sha256(text.encode('utf-8')).hexdigest()}
        identifier = digest(identity)
        games, errors, total = parse(text)
        players: dict[str, Counter] = defaultdict(Counter)
        duplicates: dict[str, list[str]] = defaultdict(list)
        for game in games:
            for color in ('White', 'Black'):
                players[game.pgn.headers.get(color, '?')][color.lower()] += 1
            duplicates[digest(game.identity())].append(f'{identifier}:{game.ordinal}')
        groups = [ids for ids in duplicates.values() if len(ids) > 1]
        dates = sorted(g.pgn.headers.get('Date', '????.??.??') for g in games
                       if re.match(r'^\d{4}', g.pgn.headers.get('Date', '')))
        summary = {'collection_id': identifier, **source, 'fingerprint': identity,
                   'records': total, 'games': len(games), 'excluded_games': len(errors),
                   'errors': errors[:50], 'errors_truncated': len(errors) > 50,
                   'duplicate_groups': groups[:50], 'duplicate_group_count': len(groups),
                   'duplicates_note': 'Same headers, start position and mainline; retained, not silently removed.',
                   'date_range': [dates[0], dates[-1]] if dates else None,
                   'unknown_year_games': len(games) - len(dates),
                   'players': [{'name': name, **counts} for name, counts in sorted(players.items())],
                   'snapshot_note': 'Immutable snapshot. Reopen changed sources to obtain a new ID.'}
        self.save('collections', identifier, {'summary': summary, 'text': text})
        self.cache.clear()
        self.cache[identifier] = (summary, games)
        return {**summary, 'players': summary['players'][offset:offset + limit],
                'player_count': len(players), 'next_offset': offset + limit if offset + limit < len(players) else None}

    def collection(self, identifier: str) -> tuple[dict, list[Game]]:
        self.path('collections', identifier)
        if identifier not in self.cache:
            saved = self.read('collections', identifier)
            if digest(saved['summary']['fingerprint']) != identifier or hashlib.sha256(
                    saved['text'].encode('utf-8')).hexdigest() != saved['summary']['fingerprint']['text_sha256']:
                raise ToolError('Collection snapshot checksum mismatch; reopen the source.')
            _require_chess()
            import chess
            if (saved['summary']['fingerprint']['parser'] != chess.__version__
                    or saved['summary']['fingerprint']['version'] != VERSION):
                raise ToolError('PGN parser/index version changed; reopen the source and search again.')
            games, _, _ = parse(saved['text'])
            self.cache.clear()
            self.cache[identifier] = (saved['summary'], games)
        return self.cache[identifier]

    def selection(self, identifier: str) -> tuple[dict, list[tuple[Game, dict]]]:
        selection = self.read('selections', identifier)
        if digest(selection) != identifier:
            raise ToolError('Selection snapshot checksum mismatch; run the search again.')
        _, games = self.collection(selection['collection_id'])
        by_id = {g.ordinal: g for g in games}
        return selection, [(by_id[m['ordinal']], m) for m in selection['matches']]
