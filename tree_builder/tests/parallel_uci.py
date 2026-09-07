#!/usr/bin/env python3
"""Deterministic, deliberately uneven UCI work with observable overlap."""
import json
import os
import sys
import time

fen = ''
threads = 1
log = os.environ.get('PARALLEL_UCI_LOG')

def event(kind):
    if log:
        payload = json.dumps(dict(kind=kind, pid=os.getpid(), t=time.monotonic(),
                                  fen=fen, threads=threads)) + '\n'
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, payload.encode())
        finally:
            os.close(fd)

for line in sys.stdin:
    words = line.split()
    if not words:
        continue
    if words[0] == 'uci':
        print('id name Parallel oracle\nuciok', flush=True)
    elif words[0] == 'isready':
        print('readyok', flush=True)
    elif words[:3] == ['setoption', 'name', 'Threads']:
        threads = int(words[-1])
    elif words[:2] == ['position', 'fen']:
        fen = ' '.join(words[2:])
    elif words[0] == 'go':
        depth = int(words[words.index('depth') + 1])
        score = sum(fen.encode()) % 101 - 50
        event('start')
        time.sleep(float(os.environ.get('PARALLEL_UCI_DELAY', '.004')) * (1 + score % 3))
        event('end')
        if os.environ.get('PARALLEL_UCI_FAIL'):
            depth = 0
        print(f'info depth {depth} score cp {score} nodes 1 pv e2e4\nbestmove e2e4', flush=True)
    elif words[0] == 'quit':
        break
