#!/usr/bin/env python3
"""Reproducible, isolated search-budget benchmark; never writes an app book.

prepare samples distinct FICS games from a previously replayable JSON archive.
run uses the production MCP engine transport, cold trees, no clocks/sitting,
and the same static two-seat offset as BughouseBackend.inspect.
"""
import argparse
import ast
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'tools/mcp'), str(ROOT / 'tools')]
import chess
from bughouse.board import DualBoard
from bughouse.engine import HivemindEngine
from bughouse.paths import EngineFiles


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare(args):
    rng = random.Random(20261002)
    games = json.loads(args.source.read_text())
    rng.shuffle(games)
    groups = {name: [] for name in ('opening', 'reserves', 'check')}
    rejected = 0
    for game in games:
        if all(len(v) >= args.per_group for v in groups.values()):
            break
        dual = DualBoard()
        choices = []
        try:
            for ply, (which, move) in enumerate(game['moves']):
                board = which.upper()
                b = dual.board(board)
                if ply >= 6 and b.legal_moves.count() >= 2:
                    pockets = sum(b.pockets[c].count(p) for c in chess.COLORS for p in range(1, 6))
                    group = 'check' if b.is_check() else 'reserves' if pockets and ply >= 20 else 'opening' if ply <= 16 and not pockets else None
                    if group and len(groups[group]) < args.per_group:
                        choices.append(dict(fen=dual.dual_fen, board=board, group=group,
                                            game=game['tags'].get('BughouseDBGameNo'), ply=ply,
                                            pockets=pockets, legal=b.legal_moves.count()))
                dual.push(board, move)
        except Exception:
            rejected += 1
            continue
        if choices:
            # Balance strata before choosing a position; never two per game.
            least = min(len(groups[c['group']]) for c in choices)
            chosen = rng.choice([c for c in choices if len(groups[c['group']]) == least])
            groups[chosen['group']].append(chosen)
    cases = [dict(id=f'{g}-{i+1:02}', **c) for g, rows in groups.items() for i, c in enumerate(rows)]
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
    (args.output / 'sampling.json').write_text(json.dumps(dict(seed=20261002, source=str(args.source),
        source_sha256=sha(args.source), groups={g:len(v) for g,v in groups.items()},
        rejected_games=rejected, limits='Small stratified pilot; not a population estimate or Elo measurement.'), indent=2)+'\n')
    print(f'Prepared {len(cases)} cases', flush=True)


def static(e, fen):
    values = []
    for team in ('white', 'black'):
        e.configure(team=team, time_advantage=False)
        e.new_game()
        e.set_position(fen)
        e.send('policy'); e.send('isready')
        output = e._read_until(lambda s:s == 'readyok', 120, 'policy')
        values.append(float(next(s[7:] for s in output if s.startswith('Value: '))))
    return values


def prepare_mates(args):
    """Extract only literal dual FENs; never execute upstream test source."""
    rows = json.loads((args.output / 'cases.json').read_text())
    seen = {r['fen'] for r in rows}
    for block in re.split(r'TEST_F\(EngineTest,\s*', args.source.read_text())[1:]:
        name = block.split(')')[0]
        if 'find_root_mate(' not in block:
            continue
        for i, match in enumerate(re.finditer(r'\w+\.set\(\s*((?:"[^"\n]*"\s*)+)\);', block)):
            fen = ''.join(ast.literal_eval(s) for s in re.findall(r'"[^"\n]*"', match[1]))
            if '|' not in fen:
                continue
            try:
                dual = DualBoard.from_dual_fen(fen)
            except ValueError:
                continue
            if dual.dual_fen in seen:
                continue
            seen.add(dual.dual_fen)
            for board in 'AB':
                if dual.board(board).legal_moves.count():
                    rows.append(dict(id=f'fixture-{name}-{i}-{board}', group='upstream-regression',
                                     board=board, fen=dual.dual_fen))
    (args.output / 'mate-cases.json').write_text(json.dumps(rows, indent=2)+'\n')
    (args.output / 'mate-cases.tsv').write_text(''.join(f"{r['id']}\t{r['board']}\t{r['fen']}\n" for r in rows))
    print(f'Prepared {len(rows)} mate-probe cases')


def prepare_rankings(args):
    """Rescore a bounded set of disagreements by searching resulting positions."""
    cases = {c['id']:c for c in json.loads((args.output/'cases.json').read_text())}
    rows = [json.loads(s) for p in args.output.glob('search-*.jsonl') for s in p.read_text().splitlines()]
    ref = {r['id']:r for r in rows if r['budget']==8000 and not r.get('repeat')}
    low = {(r['id'],r['budget']):r for r in rows if r['budget'] in (100,800) and not r.get('repeat')}
    disagreements = []
    for ident, reference in ref.items():
        if not all((ident,n) in low for n in (100,800)):
            continue
        candidates = [low[ident,n] for n in (100,800)]
        if any(r['selected_move'] != reference['selected_move'] for r in candidates):
            disagreements.append((max(abs(r['q']-reference['q']) for r in candidates),ident))
    disagreements.sort(reverse=True)
    selected=[ident for _,ident in disagreements[:args.limit]]
    for ident in args.include:
        if ident not in selected and any(name==ident for _,name in disagreements):
            selected.append(ident)
    children=[]
    for ident in selected:
        c=cases[ident]
        moves={low[ident,100]['selected_move'],low[ident,800]['selected_move'],ref[ident]['selected_move']}
        for move in sorted(moves):
            dual=DualBoard.from_dual_fen(c['fen'])
            parent_team_white=dual.board(c['board']).turn==(c['board']=='A')
            dual.push(c['board'],move)
            if not dual.board(c['board']).legal_moves.count():
                raise ValueError('Terminal ranking child needs explicit terminal adjudication')
            children.append(dict(id=c['id']+'-'+move,group='ranking',fen=dual.dual_fen,
                board=c['board'],parent=c['id'],move=move,parent_team_white=parent_team_white,
                chosen_100=low[ident,100]['selected_move'],chosen_800=low[ident,800]['selected_move'],
                chosen_8000=ref[ident]['selected_move']))
    target=args.output/'rankings';target.mkdir(exist_ok=True)
    (target/'cases.json').write_text(json.dumps(children,indent=2)+'\n')
    print(f'Prepared {len(children)} candidate children from {len(selected)} disagreements')


def run(args):
    cases = json.loads((args.output / 'cases.json').read_text())[args.shard::args.shards]
    if args.only:
        cases = [c for c in cases if c['id'] in args.only]
    path = args.output / f'search-{args.shard}.jsonl'
    existing = [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []
    done = {(r['id'], r['budget'], r.get('repeat',0)) for r in existing}
    files = EngineFiles(args.engine, args.model, args.library, 'explicit benchmark')
    with HivemindEngine(files, hash_mb=128, batch_size=8) as e, path.open('a', buffering=1) as out:
        e.set_option('Ponder', False); e.is_ready()
        manifest = dict(engine=str(args.engine), engine_sha256=sha(args.engine), model=str(args.model),
            model_sha256=sha(args.model), backend=e.backend_detail, affinity=sorted(os.sched_getaffinity(0)),
            budgets=args.budgets, cold_trees=True, time_advantage=False, ponder=False,
            reference=max(args.budgets), repeat=args.repeat)
        manifest['cases_sha256'] = sha(args.output/'cases.json')
        manifest['selected_cases'] = [c['id'] for c in cases]
        suffix = f'-repeat-{args.repeat}' if args.repeat else ''
        (args.output / f'run-{args.shard}{suffix}.json').write_text(json.dumps(manifest, indent=2)+'\n')
        for case in cases:
            dual = DualBoard.from_dual_fen(case['fen'])
            team_white = dual.board(case['board']).turn == (case['board'] == 'A')
            start = time.monotonic(); values = static(e, case['fen']); static_seconds = time.monotonic()-start
            offset = sum(values)/2
            if (case['id'], 0, args.repeat) not in done:
                out.write(json.dumps(dict(id=case['id'], group=case['group'], budget=0, repeat=args.repeat,
                    seconds=static_seconds, q=(values[0]-values[1])/2, offset=offset, static_values=values))+'\n')
            budgets = list(args.budgets)
            random.Random(case['id'] + str(args.repeat)).shuffle(budgets)
            for budget in budgets:
                if (case['id'], budget, args.repeat) in done:
                    continue
                e.configure(team='white' if team_white else 'black', require_move_on=case['board'])
                e.new_game(); e.set_position(case['fen'])
                start = time.monotonic(); result = e.search(nodes=budget); e.is_ready()
                elapsed = time.monotonic()-start
                top = result.top
                if top is None or (top.score_cp is None and top.mate is None):
                    raise RuntimeError(f'No evaluation: {case["id"]}, {budget}')
                raw = math.copysign(1,top.mate) if top.mate is not None else math.atan(top.score_cp / 180) / 1.56
                q = raw if top.mate is not None else max(-1,min(1,raw-offset))
                best = result.best.half(0 if case['board']=='A' else 1) if result.best else None
                row = dict(id=case['id'], group=case['group'], budget=budget, repeat=args.repeat,
                    seconds=elapsed, static_seconds=static_seconds, q=q if team_white else -q,
                    raw_q=raw, offset=offset, **top.as_dict())
                # top.as_dict has a joint `best`; selected-board move is distinct.
                row['selected_move'] = best
                out.write(json.dumps(row)+'\n')
                print(json.dumps({k:row[k] for k in ('id','budget','seconds','nodes','depth','q','selected_move')}),flush=True)


def percentile(xs, p):
    xs=sorted(xs)
    return xs[max(0, math.ceil(len(xs)*p)-1)]


def summarize(args):
    rows = [json.loads(s) for path in sorted(args.output.glob('search-*.jsonl')) for s in path.read_text().splitlines()]
    if args.group:
        rows = [r for r in rows if r['group']==args.group]
    refs = {r['id']:r for r in rows if r['budget']==args.reference and not r.get('repeat')}
    summary = {}
    for budget in sorted({r['budget'] for r in rows}):
        pairs = [(r,refs[r['id']]) for r in rows if r['budget']==budget and r['id'] in refs and not r.get('repeat')]
        if not pairs:continue
        errors=[abs(r['q']-ref['q']) for r,ref in pairs]
        summary[budget]=dict(n=len(pairs),median_seconds=statistics.median(r['seconds'] for r,_ in pairs),
            p90_seconds=percentile([r['seconds'] for r,_ in pairs],.9),mean_abs_q=statistics.mean(errors),
            median_abs_q=statistics.median(errors),p90_abs_q=percentile(errors,.9),max_abs_q=max(errors),
            errors_over_005=sum(x>.05 for x in errors),errors_over_01=sum(x>.1 for x in errors),
            selected_move_agreement=sum(r.get('selected_move')==ref.get('selected_move') for r,ref in pairs)/len(pairs) if budget else None,
            meaningful_sign_flips=sum(r['q']*ref['q']<0 and abs(ref['q'])>=.1 for r,ref in pairs),
            reference_mates=sum(ref.get('mate') is not None for _,ref in pairs),
            missed_reference_mates=sum(ref.get('mate') is not None and r.get('mate') is None for r,ref in pairs))
    result=dict(reference=args.reference,results=summary,reference_is_ground_truth=False)
    name = f'summary-{args.group}.json' if args.group else 'summary.json'
    (args.output/name).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


def validate(args):
    cases = {c['id']:c for c in json.loads((args.output/'cases.json').read_text())}
    rows = [json.loads(s) for p in args.output.glob('search-*.jsonl') for s in p.read_text().splitlines()]
    seen = set()
    for r in rows:
        key = (r['id'],r['budget'],r.get('repeat',0))
        assert key not in seen, f'Duplicate record: {key}'
        seen.add(key)
        assert math.isfinite(r['q']) and -1 <= r['q'] <= 1
        if not r['budget']:
            continue
        c = cases[r['id']]
        board = DualBoard.from_dual_fen(c['fen']).board(c['board'])
        assert chess.Move.from_uci(r['selected_move']) in board.legal_moves, key
        assert r['seconds'] > 0 and r['nodes'] > 0, key
    for ident in cases:
        for budget in [0,*args.budgets]:
            assert (ident,budget,0) in seen, f'Missing {ident} at {budget}'
    print(f'Validated {len(rows)} records: complete budgets, unique keys, legal selected moves, finite values.')


def summarize_mates(args):
    cases = {c['id']:c for c in json.loads((args.output/'mate-cases.json').read_text())}
    rows = [json.loads(s) for s in (args.output/'mates.jsonl').read_text().splitlines()]
    budgets = [100,300,1000,2000,3000,8000,10000,30000,100000,300000]
    keys={(r['id'],r['budget'],r['repeat']) for r in rows}
    assert len(keys)==len(rows), 'Duplicate mate records'
    assert all(r['restored'] for r in rows), 'A probe changed its input board'
    for ident in cases:
        for n in budgets:
            for repeat in range(3):
                assert (ident,n,repeat) in keys, (ident,n,repeat)
    refs={r['id']:r for r in rows if r['budget']==300000 and r['repeat']==0}
    positive={ident for ident,r in refs.items() if r['found']}
    any_proof={r['id'] for r in rows if r['found']}
    results={}
    for n in budgets:
        samples=[r for r in rows if r['budget']==n]
        first=[r for r in samples if r['repeat']==0]
        missed=sorted(positive-{r['id'] for r in first if r['found']})
        results[n]=dict(cases=len(first),proved=sum(r['found'] for r in first),
            reference_proofs_retained=len(positive)-len(missed),missed_reference_proofs=missed,
            timeouts=sum(r['timed_out'] for r in samples),
            non_playable_proofs=sum(r['found'] and not r['selected_legal'] for r in first),
            median_ms=statistics.median(r['seconds']*1000 for r in samples),
            p95_ms=percentile([r['seconds']*1000 for r in samples],.95),
            max_ms=max(r['seconds']*1000 for r in samples),
            fics_median_ms=statistics.median(r['seconds']*1000 for r in samples if cases[r['id']]['group']!='upstream-regression'))
    result=dict(cases=len(cases),calls=len(rows),reference_budget=300000,
        reference_proofs=len(positive),proofs_at_any_budget=len(any_proof),
        proofs_absent_at_reference=sorted(any_proof-positive),results=results)
    (args.output/'mate-summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    sub=p.add_subparsers(dest='command',required=True)
    s=sub.add_parser('prepare');s.add_argument('--source',type=Path,required=True);s.add_argument('--per-group',type=int,default=8)
    s=sub.add_parser('prepare_mates');s.add_argument('--source',type=Path,required=True)
    s=sub.add_parser('prepare_rankings');s.add_argument('--limit',type=int,default=4);s.add_argument('--include',nargs='*',default=[])
    s=sub.add_parser('run');s.add_argument('--engine',type=Path,required=True);s.add_argument('--model',type=Path,required=True);s.add_argument('--library',type=Path)
    s.add_argument('--budgets',type=int,nargs='+',default=[100,300,800,3000,8000]);s.add_argument('--shard',type=int,default=0);s.add_argument('--shards',type=int,default=1);s.add_argument('--repeat',type=int,default=0)
    s.add_argument('--only',nargs='+')
    s=sub.add_parser('summarize');s.add_argument('--reference',type=int,default=8000);s.add_argument('--group')
    s=sub.add_parser('validate');s.add_argument('--budgets',type=int,nargs='+',default=[100,300,800,3000,8000])
    sub.add_parser('summarize_mates')
    a=p.parse_args();globals()[a.command](a)
