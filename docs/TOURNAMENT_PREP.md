# Tournament Prep

Prepare for a whole tournament at once: import an entry list, resolve entrants
to their online accounts, work out who you are likely to play, clash your
repertoire against their actual games, and get back a ranked set of lines to
study.

Driveable from the app (Tournament Prep mode) or from Cursor / Claude Code
through the MCP bridge.

## The idea

Forty per-opponent reports are unusable — nobody studies forty people the night
before an event. But positions repeat across a field, and each one can be
scored by how likely it is to actually appear on your board:

```
score(position) = Σ over opponents  P(pair) × P(reach) × P(they play it)
```

Ranking by that collapses a field into the handful of lines worth knowing, and
tells you which opponents each line buys you.

## Pipeline

```
entry list ──▶ roster_import ──▶ identity resolution ──▶ event simulation
                                        │                       │
                                 (directory, then          P(face) per
                                  agent web search)        opponent & color
                                        │                       │
                                        └────────┬──────────────┘
                                                 ▼
                                     clash vs. each opponent's games
                                                 ▼
                                     pooled, ranked prep positions
                                                 ▼
                                   PGN (Study) · briefing · roster CSV
```

### 1. Identity resolution

Two tiers, strongest first.

**Bundled directory** (`assets/data/uscf_chesscom_map.json`) — 3,459 USCF IDs
mapped to chess.com accounts. Built by `scripts/build_player_map.py` from
USCF-rated events *hosted on chess.com*: if USCF player A faced opponent B in
round 3, and A's known chess.com account faced username Y in round 3, then
B = Y. The linkage is structural rather than inferred, which is why those rows
carry `exact` confidence — and it comes from records the players created by
entering the event, not from correlating a pseudonymous account.

Coverage is the limit, not precision. A miss means the player has not played a
USCF-rated online event, so expect a partial hit rate on any given field.
Regenerate the asset after extending the mapping:

```
python scripts/build_player_map.py          # long, rate-limited network job
python scripts/build_directory_assets.py    # regenerate the bundled assets
```

There are ~2,754 unprocessed events in `scripts/data/uscf_events_cache.json`
(everything before May 2023), so a backfill should raise coverage substantially.

**Agent search** — everyone the directory misses. An agent reads profiles and
search results and calls `identity_propose`. A proposal is stored and shown but
is **not actionable**: prep will not run against it until `identity_confirm`.
That boundary is what keeps a hallucinated username from becoming prep against
the wrong person.

### 2. Event simulation

The simulator does not predict the pairing sheet — withdrawals, late entries,
family withholds, half-point byes and TD discretion all move it, and none are
knowable in advance. It samples the whole event thousands of times and counts
opponents, which is robust to exactly that noise. Every source of mess enters
as a parameter:

| Real-world mess | Model |
|---|---|
| Family / club withhold | `constraint_add` — same constraint type as no-repeat |
| Late entry, unconfirmed | `attendance_prob` below 1.0 |
| Withdrawal | `withdrawn: true` |
| Half-point bye request | `half_point_byes: [2]` |
| Accelerated pairings | roster flag (announced by the organizer; never guessed) |

Round 1 comes out near-deterministic — it is a plain top-half/bottom-half
split, so a mid-field player faces the bottom of the field by design. Later
rounds diffuse toward the players near your rating, which is the honest answer.

`P(face)` is split by the color you would hold, because prep for an opponent
with White is a different repertoire from prep for the same opponent with
Black; the two drive separate clash runs.

### 3. Clash

`RepertoireAuditService` already walks a repertoire tree against a tree of
foreign games and emits the moves your book fails to answer. Tournament prep
points it at one person's archive, filtered to the color they will hold against
you (`AuditConfig.clashUsername` / `clashUserIsWhite`) — their games on the
other color say nothing about how they meet your repertoire.

## Pairing engine fidelity

`swiss_pairer.dart` implements the load-bearing parts of USCF Chapter 29: score
groups, top-half/bottom-half cross-pairing, no-repeat, color equalization and
alternation, pair-downs, and the odd-field bye.

It does **not** implement the full transposition/interchange limits (the
80-point and 200-point rules), rating-floor cases, or TD discretion. Those
matter for a defensible official wall chart; they do not measurably move a
*probability distribution* over opponents, because uncertainty about who wins
each game dominates them. A player who cannot be legally paired in their score
group pairs down, as a TD would; only when the score groups run out is a
pairing emitted with `forced: true` rather than silently violated.

## Two MCP servers, split by what they need

Identity work needs no chess engine, no opening tree, and no running app —
just the shipped directory, the US Chess API, and a roster file. That is also
the part an agent is genuinely good at: reading an organizer's page, searching
for profiles, judging whether two records describe the same person. It should
not require the GUI to be open, so it does not.

Chess computation is the opposite: an `OpeningTree`, the audit walk,
Stockfish, Maia and the eval cache all live in the app.

```
                    ┌──────────────────────────────┐
Cursor /  ─ stdio ─▶│ chess_prep  (Python, no deps)│──┐
Claude Code         │ directory · US Chess API ·   │  │
                    │ roster · identities          │  │  shared roster file
                    └──────────────────────────────┘  │  tournament_session.json
                    ┌──────────────────────────────┐  │
          ─ stdio ─▶│ chess_prep_mcp.mjs (shim)    │  │
                    └──────────────┬───────────────┘  │
                        loopback HTTP + token         │
                    ┌──────────────▼───────────────┐  │
                    │ Chess Auto Prep (Flutter)    │◀─┘
                    │ simulate · clash · prep      │   (watched, live)
                    └──────────────────────────────┘
```

The two halves meet at the roster file. The Python server writes it
atomically; `TournamentSession` watches the directory and reloads, so an agent
resolving twenty accounts updates an open app immediately.

> The file lives in the platform's *application support* directory, keyed off
> the application identifier — on Linux `com.example.chess_auto_prep`, on macOS
> `com.example.chessAutoPrep`. Not the Dart package name; that is a different
> directory the app never writes to. Override with `CHESS_PREP_ROSTER`.

### Standalone server — works with the app shut

```
claude mcp add chess-prep -- python3 /abs/path/to/tools/mcp/chess_prep/__main__.py
```

Zero dependencies, Python 3.10+.

| Tool | |
|---|---|
| `directory_search` | Look up a player by USCF ID, name, or chess.com username |
| `directory_stats` | Size and provenance of the bundled directory |
| `uscf_member` | US Chess API: OTB **and online** ratings for one player |
| `uscf_coverage_report` | Sweep the field: who is mappable *in principle* |
| `roster_import` | Parse a CSV/TSV or pasted entry list, and save it |
| `roster_get` | Current roster, or just the unresolved work list |
| `roster_resolve` | Match the field against the bundled directory |
| `roster_update` | Withdrawal, attendance probability, byes, rating, "this is me" |
| `identity_propose` | Propose an account **with evidence** (not actionable) |
| `identity_confirm` | Promote a proposal to usable — the human-in-the-loop step |
| `constraint_add` | Two entrants who must never be paired |
| `roster_export` | The field as CSV, provenance included |

`uscf_coverage_report` is the one to reach for first on a new field. A
directory miss is ambiguous on its own; this call separates "the mapping needs
a backfill" from "this player was never online-rated and only web search will
find them".

### In-app bridge — needs the app running

Enable **Settings → Agent bridge (MCP)**, then:

```
claude mcp add chess-prep-app -- node /abs/path/to/tools/mcp/chess_prep_mcp.mjs
```

| Tool | |
|---|---|
| `roster_get` | What the app currently holds |
| `pairing_simulate` | Monte Carlo → P(face) per entrant, split by colour |
| `repertoire_list` | Available repertoire PGNs |
| `prep_run` | The full pipeline (downloads games — the expensive call) |
| `prep_export` | `pgn` for Study, or `briefing` |

The simulator stays here rather than being ported: it is the tested numerical
core, and duplicating a Monte Carlo across two languages is how the two drift.

Bound to loopback only, bearer token minted at enable time and written to
`mcp_endpoint.json` next to the roster. Turning the toggle off deletes it.

### The trust rule, in both servers

An agent proposes; a human confirms. `identity_propose` stores an account with
its evidence but leaves it **non-actionable**; only `identity_confirm` makes
prep run against it. The roster CSV carries provenance columns so an
export/import round trip cannot launder a guess into a trusted identity.

Nothing in either server lets an agent write chess data.

## A typical session

Standalone server (app can be shut):

```
directory_stats                  → how much can resolve automatically?
roster_import                    → paste the organizer's entry list
roster_update {is_me: true}      → mark yourself if the import missed you
roster_resolve                   → exact hits, free; returns the work list
uscf_coverage_report             → of the misses, who is mappable at all?
  ... agent searches the web for the ones that are not ...
identity_propose × N             → with evidence
  ... user reviews ...
identity_confirm × N
```

Then, with the app open (it picks the roster up automatically):

```
pairing_simulate                 → who you are actually likely to play
prep_run                         → downloads games, clashes, ranks
prep_export {format: "pgn"}      → into Study
```

Once real pairings are posted, `prep_export {player_id}` gives a focused drill
for the one opponent you actually got.

## Where the code lives

```
lib/features/tournament/
  models/     player_identity · roster_entry · pairing · opponent_probability
  services/   player_directory · player_name · roster_import
              swiss_pairer · event_simulator          (pure Dart, no engine)
              identity_resolver · clash_service
              tournament_prep_service · prep_export · tournament_session
  mcp/        prep_tools · prep_server
  widgets/    roster_table · tournament_controls · prep_report_panel
lib/screens/tournament_screen.dart

tools/mcp/
  chess_prep/            standalone MCP server (Python, no dependencies)
    server.py            JSON-RPC stdio loop
    tools.py             tool registry
    directory.py         USCF → chess.com lookup + name normalization
    roster.py            roster model, entry-list parser, persistence
    uscf.py              US Chess ratings API
    paths.py             repo data + shared roster location
  chess_prep_mcp.mjs     stdio shim for the in-app bridge
  test_chess_prep.py     53 tests
  test_chess_prep_mcp.mjs  12 tests

scripts/build_directory_assets.py
```

Tests: `flutter test test/features/tournament/` (127),
`python3 tools/mcp/test_chess_prep.py` (53),
`node tools/mcp/test_chess_prep_mcp.mjs` (12).

`swiss_pairer` and `event_simulator` are pure functions with no engine,
network, or Flutter dependency — deterministic given a seed, and covered by
`test/features/tournament/`.

## Scope and limits

- **Directory coverage is partial.** Measure the hit rate on a real entry list
  before planning around it; a backfill run will improve it.
- **A name match is weaker than an ID match**, even when the underlying row is
  exact — the row is certain, the claim that it is *this* entrant is not.
  Ambiguous names return every candidate rather than a pick.
- **Rounds 4+ are diffuse.** By then the honest answer is "the ~20 people near
  your rating," and the ranking reflects that rather than pretending otherwise.
- **`prep_run` downloads games per opponent.** It skips anyone below
  `min_pairing_prob` and reports what it skipped.
