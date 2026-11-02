import 'package:flutter/material.dart';

/// Every symbol the app draws, by what it means: the one file that names
/// Material's `Icons`, so one verb has one symbol wherever it appears.
///
/// The verbs follow DESIGN.md's verb table. The rest are symbols of one
/// place (the board, a pane, a list), named for what they stand for there.
/// Outlined variants throughout; a filled one only for a toggle's on state.
abstract final class AppIcons {
  // The verbs.

  /// New and Add: makes a thing, or puts one in a set.
  static const add = Icons.add;

  /// Open and Import: reads a file in.
  static const open = Icons.file_open_outlined;
  static const save = Icons.save_outlined;

  /// Save a copy and Export: writes elsewhere, the original untouched.
  static const saveCopy = Icons.save_as_outlined;

  /// Send: to Lichess or another service.
  static const send = Icons.cloud_upload_outlined;
  static const download = Icons.download;
  static const copy = Icons.content_copy;
  static const paste = Icons.content_paste;

  /// Edit and Rename.
  static const edit = Icons.edit_outlined;
  static const delete = Icons.delete_outline;

  /// Remove: takes a thing off a list; the thing itself survives.
  static const remove = Icons.close;

  /// Run and Resume.
  static const run = Icons.play_arrow;

  /// Pause keeps the progress; [stop] ends.
  static const pause = Icons.pause;
  static const stop = Icons.stop;
  static const settings = Icons.settings_outlined;
  static const filter = Icons.filter_list;

  /// Back to the place this one was reached from.
  static const back = Icons.arrow_back;

  /// Opens the thing in another mode or pane: `Open in builder`.
  static const openElsewhere = Icons.open_in_new;
  static const restore = Icons.restore_from_trash_outlined;
  static const undo = Icons.undo;
  static const refresh = Icons.refresh;
  static const search = Icons.search;

  // The window and its menus.

  /// Forward again, the other way from [back].
  static const forward = Icons.arrow_forward;

  /// Closes a dialog, pane or tab, dismisses a line, clears a field.
  static const close = Icons.close;

  /// Done editing.
  static const done = Icons.check;

  /// The mark on the chosen entry of a menu or list.
  static const tick = Icons.check;
  static const modeMenu = Icons.menu;
  static const dropDown = Icons.arrow_drop_down;

  /// A row's `⋯` menu.
  static const more = Icons.more_horiz;
  static const hideList = Icons.keyboard_double_arrow_left;
  static const showList = Icons.keyboard_double_arrow_right;

  /// The Actions menu's submenus.
  static const panels = Icons.view_sidebar_outlined;
  static const paneTabs = Icons.tab_outlined;
  static const layout = Icons.grid_view_outlined;
  static const window = Icons.fullscreen;
  static const newPane = Icons.horizontal_split_outlined;
  static const keyboard = Icons.keyboard_outlined;

  // Lists, folds and order.

  /// A tree row whose children show, and one whose children are hidden.
  static const expanded = Icons.expand_more;
  static const collapsed = Icons.chevron_right;

  /// A fold that opens downward, and the same fold open.
  static const showMore = Icons.expand_more;
  static const showLess = Icons.expand_less;
  static const moveUp = Icons.arrow_upward;
  static const moveDown = Icons.arrow_downward;
  static const sortAscending = Icons.arrow_upward;
  static const sortDescending = Icons.arrow_downward;

  /// A stepper's or a pocket's one more and one fewer.
  static const increase = Icons.add;
  static const decrease = Icons.remove;
  static const history = Icons.history;
  static const storage = Icons.storage_outlined;

  /// The searches' Positions list.
  static const positions = Icons.list_alt;

  // The board and the moves.

  static const first = Icons.first_page;
  static const previous = Icons.chevron_left;
  static const next = Icons.chevron_right;
  static const last = Icons.last_page;
  static const flip = Icons.swap_vert;

  /// Promote variation, and make it the main line.
  static const promote = Icons.arrow_upward;
  static const mainLine = Icons.check;

  /// The game filter's `Reaching this position`.
  static const position = Icons.grid_on;

  /// The board editor's move-pieces tool.
  static const movePieces = Icons.pan_tool_alt_outlined;

  /// The opening book, closed and open.
  static const book = Icons.menu_book_outlined;
  static const bookOpen = Icons.menu_book;

  /// The engine's threat arrow.
  static const threat = Icons.gps_fixed;

  /// Back to the moment a verdict is about.
  static const moment = Icons.my_location;

  // Training.

  static const hint = Icons.lightbulb_outline;
  static const reveal = Icons.visibility_outlined;
  static const again = Icons.replay;
  static const skip = Icons.skip_next;

  /// A finished puzzle's game with the engine on.
  static const analyze = Icons.insights;
  static const solitaire = Icons.psychology_alt_outlined;
  static const won = Icons.emoji_events_outlined;
  static const rated = Icons.star;
  static const unrated = Icons.star_border;

  // Settings sections.

  static const look = Icons.palette_outlined;
  static const engine = Icons.memory_outlined;
  static const files = Icons.folder_outlined;
  static const accounts = Icons.person_outline;
  static const expectimax = Icons.account_tree_outlined;
  static const tactics = Icons.extension_outlined;
  static const training = Icons.school_outlined;
}
