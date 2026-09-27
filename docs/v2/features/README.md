# What each mode does

One file per mode of the app, written as behaviour: what is on the screen,
what the user can do, what data it touches and what can go wrong. The
`v2` rewrite builds each mode from its file here, not from the old code;
the old code is the oracle only for file formats and algorithms.

The product owner corrects these files. A row of the
[renewal plan](../../ARCHITECTURE_RENEWAL.md#order-of-work) starts only
when its spec says `Status: corrected by the owner`.

| Mode | Spec | Plan step |
|---|---|---|
| The workspace (board, moves, engine, explorer) | [workspace.md](workspace.md) | 0, 1, 6 |
| PGN Viewer | [pgn-viewer.md](pgn-viewer.md) | 6 |
| Repertoire builder (the library, the outline, the Replies tab; the mode is named for the building) | [repertoires.md](repertoires.md) | 3, 4a, 8 |
| The old builder screen, folded into Repertoire builder; oracle only | [builder.md](builder.md) | 2, 4 |
| Generation (expectimax builds, planner) | [generation.md](generation.md) | 7 |
| Checks (holes and tricks, coverage, audit) | [checks.md](checks.md) | 8 |
| Study | [study.md](study.md) | 4 |
| Repertoire trainer | [trainer.md](trainer.md) | 5 |
| Tactics | [tactics.md](tactics.md) | 9 |
| My games (your games against your book) | [my-games.md](my-games.md) | 9c |
| Books (named sets of repertoires and chapters; Back/Forward) | [books.md](books.md) | 9c |
| Player analysis, Players & prep | [players.md](players.md) | 10 |
| Databases | [databases.md](databases.md) | 11 |
| Engine tournament | [engine-tournament.md](engine-tournament.md) | 12 |
| Bughouse lab | [bughouse-lab.md](bughouse-lab.md) | 12 |
| Settings, accounts, updates, diagnostics | [settings.md](settings.md) | 13 |

## The shape of a spec

Short. Behaviour only. Under about 180 lines. Every section below, in this
order, and nothing about classes, controllers or files of the new code.

```markdown
# <Mode>

Status: draft from the old app | corrected by the owner
Old code (oracle only): `lib/screens/…`, `lib/features/…`
Plan step: N

## Purpose
Two sentences: who opens this and what they leave with.

## Screen
Where it is reached from. Then what is on it, in reading order, one line
each: panel or control, what it shows, when it is hidden or disabled.
A screenshot of the old mode in `img/<mode>.png` when one was taken.

## Actions
One line each, in the order a user meets them:
**Name** — how it is triggered → what changes on screen and on disk →
what can fail and the sentence the user sees.

## Data
What is read and written: path or table, format, what must survive a
round trip, and which other modes read the same data.

## Keep / Change / Drop
Every bold item from Screen and Actions, one per line, prefilled `Keep —
<item>`. The owner changes the word to `Change — <item>: <what>` or
`Drop — <item>`. A Drop line removes the item from the plan; it is never
ported. Quirks the owner should rule on are listed after the items.

## Questions for the owner
Anything the old code left ambiguous. Deleted once answered above.
```

A spec describes what the old mode *does today*, including its quirks, so
the owner can decide about each one. Wishes go under `Change`, never into
the description. Numbers (limits, sizes, timings) are written down when the
old code has them.
