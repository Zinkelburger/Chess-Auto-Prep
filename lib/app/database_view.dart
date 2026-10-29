import 'dart:async';

import 'package:flutter/material.dart';

import '../features/databases/database_library.dart';
import '../features/databases/databases_screen.dart';
import '../storage/master_corpus.dart';
import '../ui/app_action.dart';
import '../ui/screen_keys.dart';
import '../workspace/latest.dart';
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
  final _opens = Latest();

  @override
  void left() => _opens.cancel();

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
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) => ScreenKeys(
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
    final ticket = _opens.begin();
    final revision = library.revision;
    final kept = await library.keep(game);
    if (kept == null ||
        ticket.overtaken ||
        requests.mode != Mode.databases ||
        library.revision != revision) {
      return;
    }
    await requests.openFile(kept);
  }

  @override
  void dispose() {
    _opens.close();
    super.dispose();
  }
}
