# Design pages & the "wireframe" style

`wireframe-style.css` holds the tokens and component styles used on the design
pages the user liked (Aug 2026): a light-first, dark-aware palette with slight
blue-grey neutrals, one warm amber accent (`--accent`) for emphasis, a blue
"pick" tone for selection, green/red for added/removed, 1px hairlines, 8px
radius, **Source Sans 3** for text and **Source Code Pro** for anything
tabular or code-like. Uppercase 11px letter-spaced eyebrows for section labels
inside panes; tabular numerals in any table of numbers.

- `example-builder-wireframes.html` — Repertoire Builder layout options.
- `example-plan-wireframes.html` — the "plan a build" flow.

The TWIC site (`python/twic-position-finder/frontend/src/layouts/Base.astro`)
carries the same tokens (dark values, since the site is dark-only). Change
colours there and here together.
