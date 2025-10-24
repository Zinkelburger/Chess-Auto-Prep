# Chessable improvements
- in a PGN, define in comment blocks like {{%% start training line %%}}
- if none specified, all moves will be trained

- Define a PGN Editor: very convenient, fix errors without leaving training
- Clickable sub-variations

- Auto-next position feature
- Choose to train full line or partial line

- Publicly available courses. User's local changes are pushed to the cloud (e.g. a typo)
- Course owner(s) can review the changes and decide to integrate them into the course or not
- Improvement on lichess studies? Whats the website to train them?? simplifychess.com?
- Lichess has commentary on each move
- Does chessbase have a cloud thing as well?
- Leave reviews, ratings. Most reviewed courses go to the top

- Have to have an account above X rating to be able to make a course
- Maybe just sort by author's rating? Higher rated comes first in the results

---
# Repertoire Builder
- Different algorithms for move selection
- "Find me an unpopular but playable line" = find line with unfairly low ranking
- "Find me a tricky line" = find lines where opponent is expected to make a mistake
- "Give me a solid repertoire" = find lines with good eval, reasonable popularity, lower sharpness
- "Give me a sacrificial repertoire" = find lines that involve piece sacrifices, or pawn sacrifices. User can select what they want to sacrifice
- "Give me an easy to learn repertorie" = find lines that are the same/similar across many variations

sharpness = relative value of a tempo. (if turns were switched, how much would the eval drop? Exclude obvious recaptures)

trickiness = Sum of (Opponent Move Probability * Engine Eval) (consider the eval of all likely opponent moves when evaluating a position, instead of just the top engine move)

forcing = few opportunities to branch (of all engine moves, only the top few are any good. Instead of the opponent having many good options)

---
# Aimchess improvements
- Import tactics from lichess
- Import tactics from lichess "imported games" section
- Import tactics from chess.com
- Run local engine on games to identify mistakes/blunders, save to PGNs

"please give me the path to stockfish. Or click 'install stockfish'"

Its useful graphs:
- Graph phase of the game advantage by win rate (compare to peers?)
- To tell you about the game phase you need to study more
- Blunder rate, etc. vs peers

Idk about the graphs tbh, I just like the tactics part of aimchess

- Find positions you lose frequently (easy to implement, I already have it)
- Find positions you drop engine eval frequently but don't lose (e.g. in the line XXX you play the move c4 +0.2 instead of Ne5 +0.8, consider playing Ne5 in the future). May have 50% win rate when you should have 70% win rate
- Find positions you lose more than the database

# Chess personalities improvements
- How to categorize players based on style, not openings?
- Don't have to take a test (can have one though)
- Give account name, it downloads games, and scans for some factors, tells you your personality

# ELO estimator
- Current tools suck idk. But people like taking ELO tests

# Repertoire builder, but as an engine
- Repertoire builder implemented as an engine, you play games against it and it starts writing them 

# Opponent preparation
- Find repertoire clashes
- Find positions they're likely to lose
- Train a Maia2 model on their games, find positions they're likely to get, even if they've never played there!

- Chess.com/lichess username -> uscf ID mapping (is this unethical)?
- Database mapping would also allow for "chess.com rating -> USCF rating" correlation analysis
- Have to consider that many chess.com players don't play uscf tournaments

---
- Write it in Flutter so its cross-platform, and web????

- Free local version, paid cloud storage + ios/android app integration
