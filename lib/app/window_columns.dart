import 'package:flutter/foundation.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../ui/theme.dart';
import '../workspace/board_claim.dart';
import '../workspace/workspace.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// The columns of the window, left to right.
enum WindowPane { list, outline, workspace }

/// Which columns the window puts side by side and how wide they are: the
/// mode's list (or the Positions in its place), the outline while a
/// repertoire chapter is open, and the workspace filling the rest.
///
/// The user drags the dividers; the list column goes when hidden and the
/// outline column comes and goes with the chapter, and the widths of the
/// others stay what the user made them. The areas are the same objects for
/// the life of the window: the split view keys each pane by its area, and a
/// pane rebuilt from a new area loses what it had open.
///
/// Notifies when the user shows or hides something — the list, the
/// Positions, a page of the narrow column, a reset. The outline following
/// the chapter and the window's width changing the arrangement only set the
/// split view's areas, which redraws the columns itself.
final class WindowColumns extends ChangeNotifier {
  WindowColumns({
    required this.requests,
    required this.workspace,
    required this.lesson,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;

  /// The lesson on the board, while the user is asked to recall its moves.
  final ValueListenable<BoardClaim?> lesson;

  final controller = MultiSplitViewController();
  final _list = Area(
    data: WindowPane.list,
    size: listColumnWidth,
    min: paneMinWidth,
  );
  final _playerList = Area(
    data: WindowPane.list,
    size: playerColumnWidth,
    min: playerColumnWidth,
  );
  final _outline = Area(
    data: WindowPane.outline,
    size: outlineColumnWidth,
    min: paneMinWidth,
  );
  final _workspace = Area(
    data: WindowPane.workspace,
    flex: 1,
    min: boardPaneMinWidth,
  );

  /// Whether the window is too narrow for the list and the outline side by
  /// side: they share one column, a page each.
  bool compact = false;

  /// The page of the shared column on screen: 0 the list, 1 the outline.
  int page = 1;

  bool outlineShown = false;
  bool listShown = true;

  /// Whether the list column shows the Positions the searches found in
  /// place of the mode's own list. One switch for every mode: the finds
  /// are the same wherever they are looked at.
  bool positionsShown = false;

  bool _disposed = false;

  /// The Positions are in the list column and the column is out.
  bool get positionsUp => listShown && positionsShown;

  /// The Positions are in front of the user, so ↓ and ↑ walk them.
  bool get walksPositions =>
      positionsUp && (!compact || !outlineShown || page == 0);

  /// The list and the outline share one column, a page each.
  bool get paged => compact && outlineShown;

  /// The outline is a repertoire chapter's lines, so it is there only when
  /// a chapter that is a whole file is open. A study chapter is one game of
  /// its file, its chapters are already in its own left column, and the line
  /// operations do not mean the same thing there — so it has no outline,
  /// whichever mode the user switches to. Hide it during a lesson too: its
  /// line previews would reveal the moves the user is being asked to recall.
  bool get wantsOutline =>
      (requests.mode == Mode.repertoires) &&
      workspace.session.source != null &&
      workspace.session.game == null &&
      lesson.value == null;

  /// Puts the outline in or takes it out as the mode on screen wants, and
  /// the mode's list column with it.
  void arrangeForMode() {
    outlineShown = wantsOutline;
    arrange();
  }

  /// Puts the outline column in or takes it out when the open chapter
  /// changes what is wanted. The other two panes are left alone, so the
  /// list keeps its width and whatever it has open.
  void followOutline() {
    if (wantsOutline == outlineShown) return;
    outlineShown = wantsOutline;
    arrange();
  }

  void arrange() => controller.areas = [
    if (listShown) requests.mode == Mode.playerAnalysis ? _playerList : _list,
    if (outlineShown && !compact) _outline,
    _workspace,
  ];

  /// Folds the list and the outline into one column when [width] has no
  /// room for both at the text's [scale].
  void fit(double width, double scale) {
    final narrow = width < navigationSideBySideMinWidth * scale;
    if (narrow == compact) return;
    compact = narrow;
    arrange();
  }

  void toggleList() {
    if (_disposed) return;
    listShown = !listShown;
    arrange();
    notifyListeners();
  }

  /// The Positions in the list column, or the mode's own list back; the
  /// column comes out if it was hidden.
  void togglePositions() {
    if (_disposed) return;
    positionsShown = !positionsShown || !listShown;
    page = 0;
    listShown = true;
    arrange();
    notifyListeners();
  }

  /// The Positions in the list column, whatever was there.
  void showPositions() {
    if (positionsUp) return;
    togglePositions();
  }

  void showPage(int page) {
    this.page = page;
    notifyListeners();
  }

  /// The columns as the window first had them.
  void reset() {
    page = 1;
    _list.size = listColumnWidth;
    _playerList.size = playerColumnWidth;
    _outline.size = outlineColumnWidth;
    listShown = true;
    arrange();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    controller.dispose();
    super.dispose();
  }
}
