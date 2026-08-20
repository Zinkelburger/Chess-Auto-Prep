# Fast vs Pure Expectimax

| | Fast | Pure |
|---|---|---|
| build_ms | 1492948 | 9200930 |
| searches | 3771 | 20944 |
| total_nodes | 10947 | 90915 |
| max_ply_reached | 9 | 9 |
| build_complete | true | true |
| root_v | 0.5585423607554012 | 0.5576273010723065 |
| selected | 352 | 402 |

Shared our-move nodes with a choice in both: 171 (pure-only 18599, fast-only 364, shared w/o choice 3389)

| zone (Pure reach) | nodes | reach mass | agree | agree (mass) | regret/reach | max regret | disagree: Fast=engine-best | disagree: Pure=engine-best | Fast choice = incumbent | Fast chosen deeper than alts |
|---|---|---|---|---|---|---|---|---|---|---|
| all | 171 | 3.244 | 82.5% | 83.4% | 0.0006 | 0.019 | 3/30 | 24/30 | 157/171 | 23/126 |
| hot | 25 | 2.678 | 84.0% | 83.7% | 0.0006 | 0.019 | 2/4 | 1/4 | 21/25 | 15/22 |
| warm | 75 | 0.508 | 82.7% | 81.6% | 0.0007 | 0.008 | 1/13 | 10/13 | 67/75 | 6/56 |
| cold | 71 | 0.057 | 81.7% | 86.1% | 0.0013 | 0.018 | 0/13 | 13/13 | 69/71 | 2/48 |

## Worst disagreements (by reach × regret, Pure valuation)

| ply | reach | Pure move (V, eval) | Fast move (V in Pure, eval) | regret | Fast=incumbent | fen |
|---|---|---|---|---|---|---|
| 2 | 0.0549 | c3 (0.597, 20) | d4 (0.578, 52) | 0.019 | true | `rnbqkbnr/ppp1pppp/3p4/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2` |
| 2 | 0.2924 | Nf3 (0.545, 42) | Ne2 (0.543, 33) | 0.002 | false | `rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2` |
| 4 | 0.0492 | Nf3 (0.537, 21) | d4 (0.534, 41) | 0.003 | true | `rnbqkbnr/pp2pppp/2p5/3p4/4P3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 0 3` |
| 4 | 0.0181 | d4 (0.583, 72) | Nf3 (0.578, 61) | 0.005 | false | `rnbqkbnr/pp2pppp/2pp4/8/4P3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 0 3` |
| 6 | 0.0107 | Nc3 (0.570, 65) | d4 (0.566, 65) | 0.004 | true | `r1bqkbnr/ppp2ppp/2np4/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4` |
| 8 | 0.0068 | Re1 (0.549, 53) | d4 (0.543, 54) | 0.005 | true | `r1bqkb1r/ppp2ppp/2np1n2/1B2p3/4P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 0 5` |
| 4 | 0.0391 | Nf3 (0.568, 31) | Nc3 (0.568, 71) | 0.001 | true | `rnb1kbnr/ppp1pppp/8/3q4/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 3` |
| 6 | 0.0128 | Nc3 (0.564, 67) | c4 (0.562, 67) | 0.002 | false | `rnb1kb1r/ppp1pppp/5n2/3q4/3P4/8/PPP2PPP/RNBQKBNR w KQkq - 0 4` |
| 8 | 0.0013 | Qd5 (0.570, 76) | Be3 (0.553, 53) | 0.016 | true | `rnbqkb1r/ppp2ppp/3p4/4P3/4n3/5N2/PPP2PPP/RNBQKB1R w KQkq - 0 5` |
| 8 | 0.0026 | d4 (0.549, 53) | h4 (0.540, 56) | 0.008 | true | `r1bqkb1r/pppp1ppp/2n3n1/1B2p3/4P3/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 6 5` |
| 6 | 0.0043 | Nf3 (0.584, 77) | Bb5+ (0.579, 86) | 0.005 | true | `rnbqkbnr/pp3ppp/3pp3/2pP4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4` |
| 6 | 0.0058 | h3 (0.581, 74) | f4 (0.578, 78) | 0.003 | true | `rnbqk1nr/pp1pppbp/2p3p1/8/3PP3/2N5/PPP2PPP/R1BQKBNR w KQkq - 1 4` |
| 8 | 0.0035 | Nc3 (0.639, 155) | Nf3 (0.634, 156) | 0.005 | true | `rn1qkbnr/pb3ppp/8/4p3/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 5` |
| 8 | 0.0041 | O-O (0.544, 48) | d4 (0.540, 60) | 0.004 | true | `r1bqk2r/pppp1ppp/2n2n2/1Bb1p3/4P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 1 5` |
| 8 | 0.0055 | Be3 (0.546, 50) | Nf3 (0.543, 49) | 0.003 | true | `r1bqkbnr/pppn1ppp/4p3/8/3PN3/8/PPP2PPP/R1BQKBNR w KQkq - 1 5` |
| 8 | 0.0055 | O-O (0.567, 73) | dxe5 (0.564, 90) | 0.003 | true | `r1bqkbnr/pp1n1ppp/2pp4/4p3/2BPP3/5N2/PPP2PPP/RNBQK2R w KQkq - 0 5` |
| 6 | 0.0031 | Nc3 (0.581, 88) | Nf3 (0.577, 81) | 0.004 | false | `r1bqkbnr/pp2pppp/2n5/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 4` |
| 8 | 0.0012 | d4 (0.555, 60) | exf5 (0.548, 67) | 0.007 | true | `r1bqk1nr/pppp2pp/2n5/1Bb1pp2/4P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 0 5` |
| 6 | 0.0009 | c4 (0.599, 97) | Bd3 (0.591, 101) | 0.008 | false | `rnbqkbnr/1p1p1ppp/p3p3/2pP4/4P3/8/PPP2PPP/RNBQKBNR w KQkq - 0 4` |
| 8 | 0.0004 | exd5 (0.657, 177) | Bf4 (0.639, 164) | 0.018 | true | `rnbqkbnr/pp3ppp/2p5/3p4/3QP3/2N5/PPP2PPP/R1B1KBNR w KQkq - 0 5` |
| 8 | 0.0006 | c4 (0.596, 106) | Qe2+ (0.586, 102) | 0.011 | true | `rnbqkb1r/pp1p1ppp/5n2/2pP4/8/8/PPP2PPP/RNBQKBNR w KQkq - 1 5` |
| 8 | 0.0004 | Qe3 (0.636, 151) | e5 (0.622, 151) | 0.014 | true | `rnb1kbnr/pp1p1ppp/2p2q2/8/3QP3/2N5/PPP2PPP/R1B1KBNR w KQkq - 1 5` |
| 8 | 0.0003 | cxd5 (0.626, 140) | Nc3 (0.609, 128) | 0.017 | true | `r1bqkbnr/ppp1pppp/2n5/3pP3/2PP4/8/PP3PPP/RNBQKBNR w KQkq - 1 5` |
| 8 | 0.0005 | Nc3 (0.564, 70) | Bf4 (0.555, 68) | 0.009 | true | `r1bqkbnr/ppp2ppp/2np4/8/3NP3/8/PPP2PPP/RNBQKB1R w KQkq - 1 5` |
| 4 | 0.0108 | Nc3 (0.588, 81) | Bd3 (0.588, 94) | 0.000 | false | `rnbqkbnr/p1pp1ppp/1p2p3/8/3PP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 3` |
