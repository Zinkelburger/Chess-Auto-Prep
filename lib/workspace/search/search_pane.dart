import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../storage/chapter_files.dart';
import '../../storage/settings_store.dart';
import '../../ui/listening_state.dart';
import '../../ui/theme.dart';
import '../board/line_preview.dart';
import '../document/document_session.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'search_results.dart';
import 'search_run_bar.dart';
import 'search_settings.dart';
import 'search_status.dart';

/// The Expectimax panel: the expectimax search from the
/// board and its values.
///
/// One bar heads the panel and never moves: the button that starts,
/// pauses and resumes the search, its depth, and the gear that swaps the
/// results for the rest of the settings. Under it one line names the side
/// the search prepares, on a button that turns the board to the other, and
/// says what the search is doing.
///
/// Then, for the position on the board, every move the search looked at
/// with what it is worth when White is the prepared side and Black replies
/// as the model predicts (White), what it is worth the other way round
/// (Black), and what the engine alone says (Engine), all from White's side:
/// a move whose value for the other side sits well off the engine's is one
/// the side playing it is expected to go wrong after. Each move the model
/// was asked about also says how often it is played, and a reply that is
/// a trap by the one rule the Positions use is marked
/// `?`, and a move with traps in the lines after it says how many. The
/// table follows the board and fills in while the search runs; the search
/// itself stays where it was started. Clicking a row plays the move;
/// resting on it floats the position after it.
///
/// A search on a repertoire chapter can then be turned into lines, written
/// into a draft chapter beside it; nothing is written until asked.
class SearchPane extends StatefulWidget {
  const SearchPane({
    super.key,
    required this.fill,
    required this.session,
    required this.settings,
    this.onOpenChapter,
    this.onShowPositions,
    this.onTogglePositions,
  });

  final FillGaps fill;
  final DocumentSession session;

  /// Where the search's settings are kept: the bar, the gear and
  /// Settings ▸ Expectimax all change them here.
  final SettingsStore settings;

  /// Opens the draft the lines were written to.
  final ValueChanged<ChapterRef>? onOpenChapter;

  /// Shows the Positions, where what a search found is listed.
  final VoidCallback? onShowPositions;

  /// The bar's Positions button: shows them, or puts the list back.
  final VoidCallback? onTogglePositions;

  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane>
    with ListeningState<SearchPane> {
  final _preview = HoverPreview<LinePreview>();

  /// Whether the gear's settings are shown where the results are.
  bool _settingsOpen = false;

  /// What is typed in a box and cannot be taken; gone once it can.
  String? _invalid;

  /// Why the last press of the button did nothing. Cleared by the next.
  String? _refusal;

  /// A row was clicked and the pointer has not moved since: the rows of the
  /// new position came up under it, and floating a board over them there
  /// would hide the very rows the click asked for.
  bool _pointerStill = false;

  /// What the still pointer rests on, floated once it moves.
  LinePreview Function()? _resting;

  /// The run and the position the rows are for.
  (FillTarget?, Fen)? _rowsFor;

  (FillTarget?, Fen) get _rowsNow =>
      (widget.fill.found?.target, widget.session.cursor.fen);

  @override
  void initState() {
    super.initState();
    _rowsFor = _rowsNow;
  }

  /// Merged anew each time the pane is rebuilt from above, so [changed]
  /// runs once more then; it compares, so that costs nothing.
  @override
  Listenable listenableOf(SearchPane widget) =>
      Listenable.merge([widget.fill, widget.session.anyChange]);

  /// A row that goes takes the pointer's exit with it, so the floated board
  /// goes with the rows: at another position, or when another run starts.
  /// The values filling in as the run goes keep it.
  @override
  void changed() {
    final rowsFor = _rowsNow;
    if (rowsFor == _rowsFor) return;
    _rowsFor = rowsFor;
    _leave();
  }

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  FillRequest get _request => FillRequest.of(widget.settings.value);

  void _problem(String? invalid) {
    if (!mounted || invalid == _invalid) return;
    setState(() => _invalid = invalid);
  }

  void _toggleSettings() {
    // A box left mid-number puts its setting back before it goes.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _settingsOpen = !_settingsOpen);
  }

  /// One half-move deeper than the depth asked for, then on from the tree.
  Future<void> _deeper(int depth) async {
    if (_invalid != null) return;
    await widget.settings.update(
      widget.settings.value.copyWith(
        expectimax: widget.settings.value.expectimax.withDepth(depth + 1),
      ),
    );
    if (mounted) await _search();
  }

  Future<void> _search() async {
    if (_invalid != null) return;
    setState(() => _refusal = null);
    final refusal = await widget.fill.resume(_request, orAfresh: true);
    if (!mounted || refusal == null) return;
    setState(() => _refusal = refusal);
  }

  void _hover(Fen after, String uci, Offset anchor) {
    LinePreview shown() =>
        LinePreview(fen: after, lastMove: uci, anchor: anchor);
    if (_pointerStill) {
      _resting = shown;
      return;
    }
    _preview.rest(shown);
  }

  void _leave() {
    _resting = null;
    _preview.leave();
  }

  /// The pointer moved after a click: what it rests on floats again.
  void _pointerMoved(PointerHoverEvent event) {
    if (!_pointerStill || event.delta == Offset.zero) return;
    _pointerStill = false;
    final resting = _resting;
    _resting = null;
    if (resting != null) _preview.rest(resting);
  }

  void _play(String uci) {
    _leave();
    _pointerStill = true;
    widget.session.playMove(uci);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.fill,
      widget.session.anyChange,
      widget.settings,
      ?widget.fill.finds,
    ]),
    builder: (context, _) => LinePreviewOverlay(
      preview: _preview,
      orientation: widget.session.orientation,
      child: LayoutBuilder(
        builder: (context, size) => SingleChildScrollView(
          child: SizedBox(
            height: math.max(
              size.maxHeight,
              widget.fill.treeSaveProblem == null
                  ? searchPaneMinHeight
                  : searchRecoveryMinHeight,
            ),
            child: _panel(),
          ),
        ),
      ),
    ),
  );

  /// The bar, the status line, the results or the settings in their place,
  /// and under them whatever a failed save or a finished run offers.
  Widget _panel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SearchRunBar(
        fill: widget.fill,
        settings: widget.settings,
        settingsOpen: _settingsOpen,
        onToggleSettings: _toggleSettings,
        onProblem: _problem,
        onSearch: () => unawaited(_search()),
        onDeeper: (depth) => unawaited(_deeper(depth)),
        onShowPositions: widget.onTogglePositions ?? widget.onShowPositions,
      ),
      SearchStatusLine(
        fill: widget.fill,
        session: widget.session,
        settings: widget.settings,
        problem: _invalid ?? _refusal,
        onShowPositions: widget.onShowPositions,
      ),
      const Divider(height: 1),
      Expanded(
        child: _settingsOpen
            ? SearchSettingsView(
                settings: widget.settings,
                locked: widget.fill.running,
                onProblem: _problem,
              )
            : Listener(
                onPointerHover: _pointerMoved,
                child: SearchResults(
                  fill: widget.fill,
                  session: widget.session,
                  book: _book,
                  onHover: (row, anchor) =>
                      _hover(row.after, row.move.uci, anchor),
                  onLeave: _leave,
                  onPlay: (row) => _play(row.move.uci),
                ),
              ),
      ),
      if (widget.fill.treeSaveProblem case final problem?)
        Padding(
          padding: const EdgeInsets.all(Space.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(problem),
              Wrap(
                spacing: Space.s,
                children: [
                  OutlinedButton(
                    onPressed: () => unawaited(widget.fill.retryTree()),
                    child: const Text('Retry save'),
                  ),
                  TextButton(
                    onPressed: widget.fill.discardTreeSave,
                    child: const Text('Discard tree save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (SearchLinesRow.shows(widget.fill))
        SearchLinesRow(fill: widget.fill, onOpenChapter: widget.onOpenChapter),
      if (widget.fill.canDiscardDraft)
        TextButton(
          onPressed: widget.fill.discardDraftSave,
          child: const Text('Discard draft save'),
        ),
    ],
  );

  bool get _book =>
      widget.settings.value.expectimax.method == SearchMethod.mainline;
}
