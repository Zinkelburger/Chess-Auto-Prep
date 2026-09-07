#!/usr/bin/env python3
"""Deterministic UCI oracle for testing complete move enumeration, not strength."""
import sys
for line in sys.stdin:
    words=line.split()
    if not words: continue
    if words[0]=='uci': print('id name Pure test oracle\nuciok',flush=True)
    elif words[0]=='isready': print('readyok',flush=True)
    elif words[0]=='go':
        depth=int(words[words.index('depth')+1])
        print(f'info depth {depth} score cp 0 nodes 1 pv e2e4\nbestmove e2e4',flush=True)
    elif words[0]=='quit': break
