#!/usr/bin/env python3
"""Convert pasted Chessable reference game text into a proper PGN file.

Usage:
    python scripts/chessable_to_pgn.py input.txt output.pgn
"""

import re
import sys


def parse_chessable_text(text: str) -> list[dict]:
    games = []
    lines = text.strip().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line or line in ("Reference", "View"):
            i += 1
            continue

        # Header: "White, First vs. Black, First, Event Year"
        # Names contain commas so we split on " vs. " first, then
        # split the right half on the last comma that precedes something
        # that doesn't look like a first name (i.e. has a digit or 2+ words).
        vs_match = re.match(r"^(.+?)\s+vs\.\s+(.+)$", line)
        if vs_match and i + 1 < len(lines):
            white = vs_match.group(1).strip()
            rest = vs_match.group(2).strip()

            # Find the split between black's name and the event.
            # Chessable format: "Last, First, Event YYYY" — event portion
            # typically has a year or recognizable tournament words.
            # Strategy: split on every ", " and find the boundary where
            # the remainder looks like an event (contains a 4-digit year
            # or known event keywords).
            parts = rest.split(", ")
            black = None
            event_str = None
            for j in range(len(parts) - 1, 0, -1):
                candidate_event = ", ".join(parts[j:])
                if re.search(r"\d{4}", candidate_event):
                    black = ", ".join(parts[:j])
                    event_str = candidate_event
                    break
            if black is None:
                # Fallback: last comma split
                last_comma = rest.rfind(", ")
                if last_comma > 0:
                    black = rest[:last_comma]
                    event_str = rest[last_comma + 2:]
                else:
                    i += 1
                    continue

            # Next non-empty line should be the moves
            i += 1
            while i < len(lines) and lines[i].strip() in ("", "Reference", "View"):
                i += 1

            if i < len(lines):
                moves_line = lines[i].strip()
                # Check it looks like moves (starts with 1.)
                if re.match(r"^1\.", moves_line):
                    result_match = re.search(
                        r"\s+(1-0|0-1|1/2-1/2|\*)\s*$", moves_line
                    )
                    result = result_match.group(1) if result_match else "*"

                    # Try to extract year from event string
                    year_match = re.search(r"(\d{4})\s*$", event_str)
                    date = f"{year_match.group(1)}" if year_match else "????"
                    event = (
                        event_str[: year_match.start()].strip()
                        if year_match
                        else event_str
                    )

                    games.append(
                        {
                            "white": white,
                            "black": black,
                            "event": event,
                            "date": date,
                            "result": result,
                            "moves": moves_line,
                        }
                    )
                    i += 1
                    continue

        i += 1

    return games


def games_to_pgn(games: list[dict]) -> str:
    parts = []
    for g in games:
        headers = [
            f'[Event "{g["event"]}"]',
            f'[Site "?"]',
            f'[Date "{g["date"]}"]',
            f'[Round "?"]',
            f'[White "{g["white"]}"]',
            f'[Black "{g["black"]}"]',
            f'[Result "{g["result"]}"]',
        ]
        parts.append("\n".join(headers) + "\n\n" + g["moves"] + "\n")
    return "\n".join(parts)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.txt> <output.pgn>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], "r") as f:
        text = f.read()

    games = parse_chessable_text(text)
    if not games:
        print("No games found in input.", file=sys.stderr)
        sys.exit(1)

    pgn = games_to_pgn(games)
    with open(sys.argv[2], "w") as f:
        f.write(pgn)

    print(f"Wrote {len(games)} games to {sys.argv[2]}")


if __name__ == "__main__":
    main()
