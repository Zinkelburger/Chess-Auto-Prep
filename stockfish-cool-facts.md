https://official-stockfish.github.io/docs/stockfish-wiki/Useful-data.html

MultiPV lowers elo

Elo gain by depth (Stockfish 17.1):
```
depth:  2  vs.  1  Result:  Elo: 169.93 +/- 13.84, nElo: 218.46 +/- 15.23
depth:  3  vs.  2  Result:  Elo: 91.90 +/- 13.84, nElo: 105.93 +/- 15.23
depth:  4  vs.  3  Result:  Elo: 146.36 +/- 14.02, nElo: 178.64 +/- 15.23
depth:  5  vs.  4  Result:  Elo: 108.68 +/- 12.87, nElo: 137.24 +/- 15.23
depth:  6  vs.  5  Result:  Elo: 153.44 +/- 13.18, nElo: 201.40 +/- 15.23
depth:  7  vs.  6  Result:  Elo: 130.94 +/- 12.55, nElo: 174.49 +/- 15.23
depth:  8  vs.  7  Result:  Elo: 190.62 +/- 13.42, nElo: 262.67 +/- 15.23
depth:  9  vs.  8  Result:  Elo: 186.48 +/- 11.82, nElo: 289.17 +/- 15.23
depth:  10  vs.  9  Result:  Elo: 161.92 +/- 10.20, nElo: 278.47 +/- 15.23
depth:  11  vs.  10  Result:  Elo: 125.78 +/- 9.66, nElo: 216.12 +/- 15.23
depth:  12  vs.  11  Result:  Elo: 89.30 +/- 8.83, nElo: 160.88 +/- 15.23
depth:  13  vs.  12  Result:  Elo: 90.97 +/- 8.18, nElo: 177.21 +/- 15.23
depth:  14  vs.  13  Result:  Elo: 76.06 +/- 8.12, nElo: 147.23 +/- 15.23
depth:  15  vs.  14  Result:  Elo: 66.82 +/- 7.79, nElo: 133.97 +/- 15.23
depth:  16  vs.  15  Result:  Elo: 54.29 +/- 7.35, nElo: 114.31 +/- 15.23
depth:  17  vs.  16  Result:  Elo: 58.21 +/- 7.24, nElo: 124.71 +/- 15.23
depth:  18  vs.  17  Result:  Elo: 51.80 +/- 7.60, nElo: 105.36 +/- 15.23
```

For depth 16-18 batch analysis, 128MB or 256MB is more than enough.
- Do not allocate these giant 8GB ram chunks!
