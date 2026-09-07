#!/usr/bin/env python3
"""Independent rolling-vs-full oracle; no production search code is imported."""
import json, math, random
from pathlib import Path
r = random.Random(112358)
cases=[]
for trial in range(12):
    white=trial%2==0
    H=8
    nodes={}
    def build(ply):
        i=len(nodes)+1
        cp=r.randrange(-400,401)
        n=dict(id=i,fen='4k3/8/8/8/8/8/R7/4K3 '+('w' if ply%2==0 else 'b')+' - 0 1',depth=ply,move_uci=f'a{i:04d}',move_san=f'M{i}',history_aware=True,explored=True,engine_eval_cp=cp,move_probability=1)
        nodes[i]=n
        if ply<H:
            n['children']=[build(ply+1),build(ply+1)]
            if (ply%2==0)!=white:
                p=r.choice([.01,.1,.3,.5,.9])
                n['children'][0]['move_probability']=p
                n['children'][1]['move_probability']=1-p
        return n
    root=build(0)
    def value(n):
        cp=n['engine_eval_cp']*(1 if (n['depth']%2==0)==white else -1)
        return 1/(1+math.exp(-.00368208*cp))
    def key(n,h):
        cp=n['engine_eval_cp']*(1 if (n['depth']%2==0)==white else -1)
        return (-look(n,h),-cp,n['move_uci'])
    visited=set()
    def look(n,h,record=False):
        if record:visited.add(n['id'])
        if n['depth']>=h:return value(n)
        cs=n['children']
        vs=[look(c,h,record) for c in cs]
        return max(vs) if (n['depth']%2==0)==white else sum(c['move_probability']*v for c,v in zip(cs,vs))
    decisions=[]
    def rolling(n):
        if n['depth']==H:return value(n)
        if (n['depth']%2==0)==white:
            horizon=min(n['depth']+4,H)
            local=look(n,horizon,True)
            chosen=min(n['children'],key=lambda c:key(c,horizon))
            decisions.append(dict(id=n['id'],uci=chosen['move_uci'],horizon=horizon,value=local))
            return rolling(chosen)
        visited.add(n['id'])
        return sum(c['move_probability']*rolling(c) for c in n['children'])
    policy=rolling(root)
    full=look(root,H)
    cases.append(dict(format='opening_tree',version=4,total_nodes=len(nodes),max_depth=H,build_complete=True,
        config=dict(play_as_white=white,max_depth=H,max_eval_loss_cp=20000,search_algorithm='rolling'),tree=root,
        decisions=decisions,policy_value=policy,full_value=full,visited_nodes=len(visited),full_nodes=len(nodes)))
out=Path(__file__).with_name('rolling_expectimax_oracles.json')
out.write_text('[\n'+',\n'.join(json.dumps(c,separators=(',',':')) for c in cases)+'\n]\n')
print(json.dumps(dict(cases=len(cases),mean_policy_loss=sum(c['full_value']-c['policy_value'] for c in cases)/len(cases),
    max_policy_loss=max(c['full_value']-c['policy_value'] for c in cases),
    rolling_nodes=sum(c['visited_nodes'] for c in cases),full_nodes=sum(c['full_nodes'] for c in cases)),indent=2))
