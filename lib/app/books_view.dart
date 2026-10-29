import 'dart:async';

import 'package:flutter/widgets.dart';

import '../features/books/books_screen.dart';
import '../ui/app_action.dart';
import '../ui/screen_keys.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

/// Books: the user's books and what is in each, a screen of its own. A
/// chapter opens in the builder.
final class BooksView extends ModeView {
  BooksView(Workspace workspace, this._requests, this._modes)
    : super(workspace, readingTabs());

  final WorkspaceRequests _requests;
  final DocumentModes _modes;

  @override
  Widget list(Widget toggle) => const SizedBox.shrink();

  /// The repertoires are listed again: one made since is there to tick.
  @override
  void entered() => unawaited(_modes.library.refresh());

  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) => ScreenKeys(
    bindings: windowKeys,
    child: Focus(
      autofocus: true,
      child: Builder(
        builder: (context) => BooksScreen(
          books: workspace.books,
          onAddRepertoire: () => _requests.switchTo(Mode.repertoires),
          catalog: _modes.library.catalog,
          onOpenChapter: (ref) =>
              unawaited(_requests.readInBuilder(ref, const [])),
        ),
      ),
    ),
  );

  @override
  Listenable get changes => workspace.books;

  @override
  List<AppAction> actions(ModeMenu menu) => [
    AppAction('New opening book', menu.dialogs.newBook, group: 'Opening books'),
  ];
}
