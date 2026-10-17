# The "wireframe" style

`wireframe-style.css` holds the tokens and component styles for design pages
and wireframes: a light-first, dark-aware palette with slight blue-grey
neutrals, one warm amber accent (`--accent`) for emphasis, a blue "pick" tone
for selection, green/red for added/removed, 1px hairlines, 8px radius,
**Source Sans 3** for text and **Source Code Pro** for anything tabular or
code-like. Uppercase 11px letter-spaced eyebrows for section labels inside
panes; tabular numerals in any table of numbers. Link it from a new design
page or wireframe rather than inventing another style.

This stylesheet is for design pages and wireframes only. The app's own values
live in `lib/ui/theme.dart` and [DESIGN.md](../../DESIGN.md); the website keeps
its own tokens in `python/twic-position-finder/frontend/src/layouts/Base.astro`
(muted blue accent, not this amber).
