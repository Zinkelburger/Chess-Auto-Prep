# What each mode does

One file per mode, written as behaviour: what is on the screen, what the user
can do, what data it touches and what can go wrong. Each describes the app as
it is now and names the code it lives in. The owner corrects these files; an
explicit owner decision in a spec or in the current task outranks everything
else here.

| Mode or area | Spec |
|---|---|
| The workspace (board, moves, engine, explorer, panes, tabs) | [workspace.md](workspace.md) |
| PGN Viewer | [pgn-viewer.md](pgn-viewer.md) |
| Repertoire builder (library, chapter outline, Replies, Audit, import) | [repertoires.md](repertoires.md) |
| Expectimax search and generated lines | [generation.md](generation.md) |
| Opening books (named sets of repertoires and chapters) | [books.md](books.md) |
| Repertoire trainer and the shared Train tab | [trainer.md](trainer.md) |
| Study | [study.md](study.md) |
| Tactics | [tactics.md](tactics.md) |
| My games (your games against your book) | [my-games.md](my-games.md) |
| Player analysis, Players & prep | [players.md](players.md) |
| Databases | [databases.md](databases.md) |
| Engine tournament | [engine-tournament.md](engine-tournament.md) |
| Bughouse | [bughouse.md](bughouse.md) |
| Settings, accounts, updates, diagnostics | [settings.md](settings.md) |

## The shape of a spec

Short, behaviour first, about 250 lines at most. Sections in this order:

```markdown
# <Mode>

Two to four sentences: who opens it and what they leave with.

Code: `lib/features/<mode>/`, plus the shared owners it leans on.

## Screen
Where it is reached from, then what is on it in reading order, one line
each, with the labels the code uses.

## Actions
**Name** — trigger → what changes on screen and on disk → what can fail and
the sentence the user sees.

## Data
Files and tables read and written, formats, what must survive a round trip,
and which other modes read the same data.

## Owner decisions
Binding product decisions, dated, written as rules.
```

A spec describes what the app does. Do not list things it does not do: that
reads as a request, and agents build it. New work comes from the owner.

When behaviour changes, rewrite the affected lines rather than appending a
dated diary entry. Numbers (limits, sizes, timings) are written down when the
code has them. Architecture rules live in [ARCHITECTURE.md](../ARCHITECTURE.md),
not in specs.
