#!/usr/bin/env python3
"""Independent finite-tree oracle: regenerate the shared Dart/C fixtures.

This constructs abstract action trees, solves max/expectation directly, and
stores each node's answer. Production serialization and scorer code is not used.
"""
from pathlib import Path
import random,json,math
w=Path(__file__).resolve().parents[2]
r=random.Random(91052);cases=[]
for k in range(30):
 white=k%2==0;counter=[0];depth=4
 def build(ply):
  counter[0]+=1;i=counter[0];stm=ply%2==0;cp=r.randrange(-500,501)
  n=dict(id=i,fen='4k3/8/8/8/8/8/R7/4K3 '+('w' if stm else 'b')+' - 0 1',depth=ply,move_uci=f'a{i:04d}',move_san=f'M{i}',history_aware=True,explored=True,engine_eval_cp=cp,move_probability=1)
  if ply==depth:
   v=1/(1+math.exp(-.00368208*(cp if stm==white else -cp)))
   if k%3==0:n['terminal_value']=v=r.choice([0,.5,1])
  else:
   children=[build(ply+1) for _ in range(r.randint(2,4))];n['children']=children
   if stm==white:
    best=max(c['engine_eval_cp']*(1 if (ply+1)%2==0 and white or (ply+1)%2!=0 and not white else -1) for c in children)
    def ec(c):return c['engine_eval_cp']*(1 if ((ply+1)%2==0)==white else -1)
    eligible=[c for c in children if ec(c)>=best-200]
    chosen=sorted(eligible,key=lambda c:(-c['expected_value'],-ec(c),c['move_uci']))[0]
    v=chosen['expected_value'];n['expected_pick']=chosen['id']
   else:
    weights=[r.randint(1,100) for _ in children];total=sum(weights)
    for c,t in zip(children,weights):c['move_probability']=t/total
    v=sum(c['move_probability']*c['expected_value'] for c in children)
  n['expected_value']=v;return n
 root=build(0)
 cases.append(dict(format='opening_tree',version=4,total_nodes=counter[0],max_depth=4,build_complete=True,config=dict(play_as_white=white,max_depth=4,max_eval_loss_cp=200),tree=root))
p=w/'test/fixtures/pure_expectimax_oracles.json';p.parent.mkdir(exist_ok=True);p.write_text('[\n'+',\n'.join(json.dumps(c,separators=(',',':')) for c in cases)+'\n]\n')
