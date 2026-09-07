# PGN reading layout

The viewer implements the [Anchored document prototype](https://pgn-reading-lab.stampsecretion.chatgpt.site/?concept=anchor).

Moves and explanations live in one continuous document. The paper background
is `#1e2126`; comments use Inter at 17px with 1.72 line height. Annotation
headings use Source Code Pro at 16px, and quiet runs of moves use 15px. Comments
retain that reading size inside variations. There is no separate position-note
panel and no empty annotation placeholder.

Navigation anchors the selected passage near the top of the document. Reading
options also offer middle and bottom anchors. Scrolling through the text leaves
the board alone; **Back to current move** or **Esc** resumes following it. A long
annotation pins its original move heading until the end of that passage, rather
than copying the heading or note into another panel.

Variations appear where they branch in the PGN. Short, unannotated alternatives
can stay inline; other lines have a disclosure labelled by their first numbered
move. Deep lines fold by default, and entering a move reveals its ancestors.
Indentation is bounded so nested notes do not become a narrow column. The
reading-options menu can expand all lines or fold deep ones.

**Focus variation** / **Ctrl+Enter** explicitly reads the current variation at
full width. It never activates automatically because a line is long. Move-based
breadcrumbs preserve the path. **Parent line** / **Ctrl+Left** returns one branch
level; **Main line** / **R** returns to the mainline branch point. Returning from
focused reading restores the parent's saved scroll position. Left/right and the
existing move buttons continue through the selected line. In solitaire, R keeps
its existing reveal meaning.

Collection navigation lives beneath the board, leaving the text pane's height
for reading. The reusable reader retains its own compact move controls.

`PgnReadingPane` owns scrolling and focus bookmarks; `PgnMovetextView` owns the
document and disclosures; `PgnReadingPassage` pins a single heading within its
annotation. Board navigation and PGN persistence remain with the existing
viewer model. Tests in `test/widgets/pgn_reading_pane_test.dart` exercise the
reading/navigation boundary, nested focus, folding, and long annotations.
