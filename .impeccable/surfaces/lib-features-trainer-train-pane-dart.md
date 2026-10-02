---
version: 1
slug: "lib-features-trainer-train-pane-dart"
primary_target: "lib/features/trainer/train_pane.dart"
related_targets: ["lib/features/trainer/training_home.dart", "lib/features/trainer/training_outline.dart", "lib/features/trainer/training_selection.dart", "lib/workspace/training_analysis_pane.dart"]
---

Mode: Operate. Existing desktop visual system and three-panel workspace are authoritative. The user approved repertoire-first training with chapter/line actions, saved progress and optional manual difficulty ratings.

## Direction contract
THESIS: Open one repertoire and learn its next new line; browsing is optional and never starts a quiz implicitly.
OWN-WORLD: Preserve DESIGN.md charcoal surfaces, slate action, shared controls, typography, adjustable panes and board.
STORY: Choose a repertoire once; Learn, Review or browse; stop and reopen with the same repertoire and completed progress.
FIRST VIEWPORT: Left selected repertoire switcher and chapter/line outline; middle shared board; right Train pane with scope name, learned/total and due counts, a prominent Learn action and outlined Review action. Other tabs split alongside Train.
FORM: User-pinned three-panel composition, refining the existing workspace; no concept roll is needed. Learning shows then tests; review offers due/all/selected lines and optional Again/Hard/Good/Easy. Help opens a reversible study detour at the lesson position.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Shipped evidence

The repertoire-first home and outline extend the incumbent system with shared
ChoiceField, SearchField, CheckRow and RowActions controls, theme typography
and spacing, a filled Learn action and outlined Review action. The board and
movable, splittable tool tabs remain shared. Trainer engine controls live only
in Analysis; Study position reveals that pane and Return to training restores
the concealed lesson.

Finish disposition: **ship**, with no material fixes. The review and synthetic
headless screenshot provenance are recorded in
[`trainer-review.md`](../review/trainer-review.md). The final study and split
lesson captures support the preserved charcoal/slate palette, flat pane
boundaries and three-panel composition. DESIGN.md and its sidecar remain
unchanged because this is an ordinary extension of the existing system.
