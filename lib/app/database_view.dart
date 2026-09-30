import 'dart:async';

import 'package:flutter/material.dart';

import '../features/databases/database_library.dart';
import '../features/databases/databases_screen.dart';
import '../storage/master_corpus.dart';
import '../ui/app_action.dart';
import '../workspace/workspace_tabs.dart';
import '../workspace/workspace.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

final class DatabasesView extends ModeView {
  DatabasesView(Workspace workspace, this.library, this.requests)
    : super(workspace, readingTabs());

  final DatabaseLibrary library;
  final WorkspaceRequests requests;
  int _request = 0;

  @override
  void left() => _request++;

  @override
  Listenable get changes => library;

  @override
  void entered() {
    unawaited(library.refresh());
    unawaited(library.measure());
  }

  @override
  Widget list(Widget toggle) => const SizedBox.shrink();

  @override
  List<AppAction> actions(ModeMenu menu) => [
    AppAction(
      'Refresh databases',
      () => unawaited(library.refresh()),
      group: 'Databases',
    ),
    AppAction(
      'Import PGN…',
      library.activity == DatabaseActivity.idle && !library.busy
          ? () => unawaited(library.importFile())
          : null,
      group: 'Databases',
    ),
  ];

  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) =>
      CallbackShortcuts(
        bindings: windowKeys,
        child: Focus(
          autofocus: true,
          child: DatabasesScreen(
            library: library,
            onOpen: (game) => unawaited(_open(game)),
          ),
        ),
      );

  Future<void> _open(CorpusGame game) async {
    final request = ++_request;
    final revision = library.revision;
    final kept = await library.keep(game);
    if (kept == null ||
        request != _request ||
        requests.mode != Mode.databases ||
        library.revision != revision)
      return;
    await requests.openFile(kept);
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }
}
