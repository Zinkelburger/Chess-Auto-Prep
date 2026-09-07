# Documentation updates

Update documentation when behavior, a public API, file layout or a planned
feature's status changes. Routine implementation edits need no documentation
ceremony. Read and update the affected section, not every document.

| Document | Role |
|---|---|
| `docs/COMPONENT_MAP.md` | Implemented components, public APIs and data flows |
| `docs/FUTURE_FEATURES.md` | Unbuilt/incomplete backlog; use Not started, Partial or Deferred |
| `docs/ALGORITHM.md` | Tree-generation pipeline detail |
| `docs/tree-display-architecture.md` | Eval-tree graph design |

Rewrite stale descriptions in the affected section. When implementing a
backlog item, remove it or update its remaining scope/status. Cross-link
algorithm details rather than duplicating them. Do not add one-off feature
specs under `docs/specs/`; extend the relevant existing document.
