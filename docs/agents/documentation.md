# Documentation updates

Update documentation when behavior, a public API, file layout or a planned
feature's status changes. Routine implementation edits need no documentation
ceremony. Read and update the affected section, not every document.

| Document | Role |
|---|---|
| `docs/features/*.md` | One spec per mode: screen, actions, data, owner decisions |
| `docs/COMPONENT_MAP.md` | Where components live, public APIs and data flows |
| `docs/ARCHITECTURE.md` | Contracts every change follows: layers, ownership, writes, recovery, engines, UI |
| `docs/DATA_INTEGRITY.md` | Every store, its format and its recovery files |
| `docs/ALGORITHM.md` | Expectimax and tree-generation detail (app, C builder, MCP) |
| `docs/HIVEMIND.md` | The bughouse engine end to end |
| `docs/ENGINE_TOURNAMENT.md`, `docs/OPPONENT_PREP.md`, `docs/BROADCAST_GAMES.md` | MCP and command-line tools for tournaments, players and broadcast collections |
| `docs/SCID_FORMAT_FINDINGS.md`, `docs/MUTATION_TESTING.md` | Scid format reference; the mutation-testing harness |
| `DESIGN.md`, `PRODUCT.md` | Visual and copy specification; product purpose and principles |

Describe the current app only. Rewrite stale lines instead of appending dated
history; Git keeps the past. There is no backlog: do not keep lists of
features the app lacks, "not built" sections or future plans; new work comes
from the owner's current request. A known limitation of what exists is written
as current behaviour where that behaviour is described. Cross-link algorithm
details rather than duplicating them. Do not add one-off plans, audits or specs as new files;
extend the relevant existing document.
