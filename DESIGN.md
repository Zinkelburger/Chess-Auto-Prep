---
name: Chess Auto Prep
description: A calm, dark desktop workspace for a tournament player's opening preparation.
colors:
  slate-accent: "#8EAAD2"
  slate-fill: "#3A5A85"
  charcoal-surface: "#1B1B1D"
  graphite-panel: "#242427"
  selection-grey: "#38383D"
  reading-black: "#0C0C0E"
  outline-grey: "#3A3A3E"
  button-outline: "#5A5A60"
  ink: "#E6E6E8"
  muted-ink: "#9A9AA0"
  disabled-fill: "#2C2C30"
  disabled-ink: "#8A8A90"
  board-light: "#F0D9B5"
  board-dark: "#B58863"
  review-inaccuracy: "#56B4E9"
  review-mistake: "#E69F00"
  review-blunder: "#E5534B"
  result-white: "#A4A4AA"
  result-draw: "#55555B"
  result-black: "#2A2A2E"
typography:
  title:
    fontFamily: "Inter, Noto Sans Symbols 2"
    fontSize: "18px"
    fontWeight: 600
  body:
    fontFamily: "Inter, Noto Sans Symbols 2"
    fontSize: "14px"
    fontWeight: 400
  body-small:
    fontFamily: "Inter, Noto Sans Symbols 2"
    fontSize: "13px"
    fontWeight: 400
  label:
    fontFamily: "Inter, Noto Sans Symbols 2"
    fontSize: "12px"
    fontWeight: 500
  button:
    fontFamily: "Inter, Noto Sans Symbols 2"
    fontSize: "14px"
    fontWeight: 600
  mono:
    fontFamily: "Source Code Pro, Noto Sans Symbols 2"
    fontSize: "13px"
    fontWeight: 400
  reading-moves:
    fontFamily: "Source Code Pro, Noto Sans Symbols 2"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.7
  reading-prose:
    fontFamily: "Inter, Noto Sans Symbols 2"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  tab: "6px"
  card: "8px"
spacing:
  xs: "4px"
  s: "8px"
  m: "12px"
  l: "16px"
  xl: "24px"
components:
  button-primary:
    backgroundColor: "{colors.slate-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
  button-primary-disabled:
    backgroundColor: "{colors.disabled-fill}"
    textColor: "{colors.disabled-ink}"
  button-outlined:
    textColor: "{colors.ink}"
    typography: "{typography.button}"
  button-text:
    textColor: "{colors.slate-accent}"
    typography: "{typography.button}"
  pane-tab:
    backgroundColor: "{colors.selection-grey}"
    textColor: "{colors.ink}"
    rounded: "{rounded.tab}"
    height: "34px"
  menu:
    backgroundColor: "{colors.graphite-panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
  reading-card:
    backgroundColor: "{colors.reading-black}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "24px"
  list-row:
    textColor: "{colors.ink}"
    height: "34px"
---

# Design System: Chess Auto Prep

## Overview

**Creative North Star: "The Quiet Analysis Room"**

A club player's analysis room late in the evening: one lit board, the moves
written out beside it, everything else in shadow. The interface is charcoal
and grey so the board, the light-and-brown squares and the moves carry the
screen. It is an Operate surface for long desk sessions with mouse and
keyboard; density is high but calm, and nothing moves or changes size while
the player is reading.

Colour is information, never mood. The one accent is a slate blue that marks
what can be clicked without pulling the eye; red, amber and blue appear only
as review marks and Lichess-style board shapes. Conventions follow lila
(Lichess): its board, its arrow colours and geometry, its explorer table, its
compact engine lines. When in doubt, do what Lichess does, quieter.

The system is dark only. There is no light theme and no appearance setting.

**Key Characteristics:**
- Charcoal surfaces in three steps, with a near-black reading card under the moves.
- One slate-blue accent; every other hue means a specific chess fact.
- Inter for interface, Source Code Pro for moves and numbers, bundled figurines.
- Flat: depth comes from tonal steps and 1px outlines, not shadows.
- Fixed heights for rows, feedback lines and panes so reading never jumps.

## Colors

Neutral charcoal with a single desaturated blue; all other colour is semantic.

### Primary
- **Slate Accent** (slate-accent): links, text buttons, focus and the dragged pane divider. It marks what is clickable without competing with the board.
- **Slate Fill** (slate-fill): background of the one filled button on a surface, the action that applies or completes the task (5.8:1 with ink).

### Neutral
- **Charcoal Surface** (charcoal-surface): the window, scaffold and most panes.
- **Graphite Panel** (graphite-panel): menus, popovers and raised containers.
- **Selection Grey** (selection-grey): the chosen tab, the selected row.
- **Reading Black** (reading-black): the reading card behind the moves; the old app's "regal" pane.
- **Outline Grey** (outline-grey): pane borders, dividers, menu edges.
- **Button Outline** (button-outline): outlined buttons' stroke, a step brighter so it reads as on.
- **Ink** (ink) and **Muted Ink** (muted-ink): primary text; secondary text, captions and column headers.
- **Disabled Fill / Disabled Ink**: unavailable controls, still legible at 4:1.

### Semantic
- **Board Light / Board Dark**: Lichess brown squares; last move and selection in translucent green.
- **Review Inaccuracy / Mistake / Blunder**: the ?!, ? and ?? marks and their graph points, nowhere else.
- **Board shapes**: Lichess green (no key), red (Shift, and the engine threat), blue (Alt), yellow (Ctrl).
- **Result White / Draw / Black**: the explorer's result bar, kept dimmer than the moves beside it.

### Named Rules
**The Colour-Is-A-Fact Rule.** A hue appears only when it tells the player something the text does not: solved or failed, a mistake mark, a state. No decorative colour, no tinted section backgrounds, no coloured icons for flavour.

**The One Filled Button Rule.** A surface has at most one Slate Fill button, and it applies or completes the task. Everything else is outlined or text.

## Typography

**Display Font:** none; the app has no display tier.
**Body Font:** Inter (with Noto Sans Symbols 2 for figurines)
**Label/Mono Font:** Source Code Pro (with Noto Sans Symbols 2)

**Character:** A plain, legible sans for every control and sentence, and a monospace for anything a chess player reads as notation: moves, FENs, evaluations, counts in tables.

### Hierarchy
- **Title** (600, 18px): dialog and pane headings; rare.
- **Body** (400, 14px): default interface text and button labels (600 for buttons).
- **Body Small** (400, 13px, muted ink): secondary lines, status, tooltips' context.
- **Label** (12px, muted ink): column headers, captions, field labels. 12px is the floor for all text except board coordinates.
- **Mono** (13px): moves, scores and numbers in tables and engine lines.
- **Reading Moves** (16px mono, 1.7 line height) and **Reading Prose** (16px, 1.55): the reading card's movetext and comments; prose capped at 640px measure.

### Named Rules
**The Twelve-Pixel Floor Rule.** Nothing the player must read is smaller than 12px; only board coordinates go below.

**The Notation-Is-Mono Rule.** If a chess player would write it on a scoresheet or read it off an engine, it is Source Code Pro.

## Layout

The window is a top bar (mode name, Actions, Settings), a document tab strip,
an optional left list column, then the workspace: the board column (board,
compact engine lines, typed-move field, note card) beside the reading card's
panes, first shared two parts board to three parts card. Panes split right or
below from a tab's context menu; each pane has a browser-style tab strip
(34px tabs, the chosen one filled). The Repertoire builder starts split:
Moves on the left, Expectimax on the right; the book opens under the moves
from its button.

Spacing is a five-step scale (4, 8, 12, 16, 24); every gap is one of them.
The list column starts 260px wide (300px in Player analysis) and the outline
220px. Below 1480px, scaled with text size, the repertoire list and chapter
outline share one 260px column with Repertoires/Chapters tabs; both remain
available and keep their searches. Wider windows show both columns. The
dividers drag, and so does the gap between two tool panes. The builder's Moves
start at 45% of the card beside Expectimax, with a preferred 280px reading width
before text scaling. Rendered pane widths respect their contents, including
nested splits, while keeping the player's saved proportions for wider windows. Minimums keep
content usable: 180px for any pane, 320px for the board column, 300px for the
reading card, 320px for a tool pane (180px for Moves, 240px for Expectimax). A
tool picked while the card is one pane opens under it, so a tool pane is laid
out to work at half the card's height. A pane shorter
than its content's minimum scrolls as a whole rather than squeezing a list to
nothing. Rows are fixed: 34px list rows, 28px engine and reply rows, 32px
search rows, 44px two-line trainer rows.

### Named Rules
**The Still Page Rule.** Reading views never shift: fixed-height feedback lines, panes and rows keep their size whether they hold anything or not, and hover never resizes a row.

## Elevation & Depth

Flat by default. Depth is tonal: reading black under charcoal under graphite,
separated by 1px outline-grey lines. Menus and popovers are graphite with an
outline and an 8px radius, not a shadow. Ink splashes and highlight washes
are off. The only floating surface is the 200px preview board that appears
80ms after the pointer rests on a move.

### Named Rules
**The No-Shadow Rule.** Separate surfaces with a tonal step or a 1px outline, never a drop shadow or glow.

## Shapes

Gently rounded containers (8px) for the reading card, menus and dialogs;
tabs at 6px; buttons use Material's stadium shape. Pane borders are 1px, the
active pane's a brighter grey. Dividers between panes are 1px lines with a
4px grab area each side. The board is square-cornered, as on Lichess.

## Components

### Buttons
- **Shape:** Material 3 stadium; labels 14px at weight 600.
- **Primary (filled):** ink on Slate Fill; one per surface, for applying or completing.
- **Outlined:** ink in a Button Outline stroke; the default secondary action.
- **Text:** slate accent, for light actions inside rows and bars.
- **Disabled:** Disabled Fill / Disabled Ink. Options that cannot apply are hidden with a one-line reason rather than shown greyed.
- **Hover / Focus:** no splash and no highlight wash; Material's state layer only.

### Pane tabs
- **Style:** 34px tall, up to 220px wide, 6px radius; the chosen tab filled in Selection Grey; a 2px line shows where a dragged tab will land. Tabs close from the right-click menu.

### Inputs / Fields
- **Style:** shared `search_field`, `choice_field`, `number_field` controls with a label above and an underline; search always shows its magnifier and clear action.
- **Choices:** typeable ChoiceField, NumberStepper or a segmented button. Never a dropdown the player cannot type into.
- **Filters:** compact Field / Rule / Value rows; selected sets as removable chips.

### Lists and tables
- **Rows:** fixed height, ink on charcoal, the selected row in Selection Grey. Numbers right-aligned in mono gutters (engine score 54px, explorer games 96px).
- **Result bar:** three grey parts with their own quiet ink, at most 220px wide.

### Tool panes (Expectimax is the pattern)
- **Bar:** a fixed-height row that never reflows: the pane's one action (a button that keeps its place and width whatever it says: Expectimax, Pause, Resume), the one or two values changed on every use, and a gear at the end.
- **Status:** one fixed-height line under the bar: what will run, then progress, then the outcome or the problem. A secondary action for the running state sits at its end. A fact that frames the whole pane sits at its start as a text button that names it and changes it (Expectimax: the side prepared, which turns the board).
- **Value table:** a fixed header and 32px rows; the move takes the room left by fixed mono gutters (48px share, 56px values). A pane too narrow drops the least needed column whole (Played) rather than squeezing any.
- **Gear:** swaps the pane's content in place for the remaining settings, one named row each with a one-line explanation on screen, and back. The same rows appear as a Settings group and write the same saved values. While the action runs they are shown but locked, with one line saying why.

### Engine lines
- **Style:** the old inline-bar style, not a Lichess headline: a small switch and status, then 28px rows with a 54px score gutter and the moves after it. Hovering a move floats its board.

### Reading card (signature)
- **Style:** Reading Black card, 8px radius, 24px inset; movetext in 16px mono at 1.7, comments in 16px prose at a 640px measure. Mistakes are marked and clickable; no per-move evaluations in the movetext.

## Do's and Don'ts

### Do:
- **Do** keep every gap on the 4 / 8 / 12 / 16 / 24 scale and every size in `lib/ui/theme.dart`.
- **Do** reuse the controls in `lib/ui/` (search_field, choice_field, number_field, field_row, check_row, toggle_chip, name_dialog, confirm_dialog, row_actions, pane_tabs, selection, app_action). A stepper or choice sits in a `field_row` that names it; a set of on/off choices is `toggle_chip`s, which never grow a tick.
- **Do** write labels and tooltips behaviour-first: the first sentence says what the control does; the binding comes from `ui/app_keys.dart`.
- **Do** follow Lichess conventions for the board, arrows, explorer and engine lines.
- **Do** give feedback lines, rows and panes fixed heights so nothing jumps.

### Don't:
- **Don't** add a light theme, a system theme or an appearance setting.
- **Don't** use colour or icons for decoration; colour marks a chess fact or a state only.
- **Don't** use a dropdown menu the player cannot type into.
- **Don't** write status sentences, filler empty states, rationale or history into the UI.
- **Don't** show text below 12px except board coordinates.
- **Don't** add shadows, glows, gradients or splash effects.
- **Don't** put an evaluation bar on the board or per-move evaluations in the movetext.
- **Don't** duplicate a control that already exists on the same screen.
