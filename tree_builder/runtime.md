
Depth: 6 ply
Engine depth: 15
Nodes: 2,074
Engine evals: 880 (72.6ms avg per eval)
Lichess queries: 658
Total time: 23.4 minutes
The bulk of that time is two things: Lichess API queries (with a 500ms rate-limit delay each = ~5.5 min just in wait time) and Stockfish evals (880 × 73ms = ~1 min of compute, but serialized across 4 engine threads).

For a 15-ply run, the scaling is roughly exponential because the tree branches at every opponent node. Some rough estimates:

At depth 6, you have 2,074 nodes. The branching factor from the tree is roughly 3-4 children per opponent node.
Going from 6 to 15 ply adds 9 more levels. Even conservatively, each added ply multiplies nodes by ~2-3x (opponent nodes branch, our nodes pick best or a few candidates).
A 15-ply tree from this root could easily hit 50,000-200,000+ nodes depending on pruning thresholds.
Lichess queries: each new opponent node needs one, at 500ms rate limit. 50k queries = ~7 hours of just waiting on the API.
Engine evals: at 73ms avg, 100k evals = ~2 hours of Stockfish compute.
Ballpark: a 15-ply run would likely take 8-24+ hours depending on how aggressively the mass/probability thresholds prune branches.

The engine-injected line fix from the plan wouldn't significantly change total runtime -- those subtrees only use Stockfish (fast, no API delay), and they're single lines (no branching), so they add maybe seconds per injected move, not minutes.

