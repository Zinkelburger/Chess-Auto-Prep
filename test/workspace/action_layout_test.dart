import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/action_layout.dart';
import 'package:chess_auto_prep/workspace/explorer/explorer.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late Explorer explorer;

  setUp(() async {
    fixture = await openSession('[Result "*"]\n\n1. e4 *');
    settings = SettingsStore();
    explorer = explorerOver(fixture.session, settings: settings);
  });

  tearDown(() {
    explorer.dispose();
    settings.dispose();
    fixture.dispose();
  });

  /// The PGN Viewer's layout: Moves alone in one pane.
  ActionLayout viewer() {
    final layout = ActionLayout(viewerTabs(), explorer);
    addTearDown(layout.dispose);
    return layout;
  }

  test('unless a mode asks, a picked tab joins its pane and Analysis is not '
      'given one of its own', () {
    final layout = viewer();
    layout.open(0, WorkspaceTab.explorer);
    expect(layout.count, 1);
    expect(layout.openIn(0), [WorkspaceTab.moves, WorkspaceTab.explorer]);
    final beside = ActionLayout(viewerTabs(), explorer, opensBeside: true);
    addTearDown(beside.dispose);
    expect(beside.canSplit(WorkspaceTab.explorer), isTrue);
    expect(beside.canSplit(WorkspaceTab.analysis), isFalse);
  });

  test('a saved layout that is not one is refused', () {
    final layout = viewer();
    expect(layout.restore('[]'), isFalse);
    expect(layout.restore('{"panes": 1}'), isFalse);
    expect(layout.count, 1);
  });

  test('the card holds one to four panes, and no more is offered at four', () {
    final layout = viewer()..arrange(2);
    expect(layout.count, 2);
    expect(layout.openIn(1), [WorkspaceTab.explorer]);
    layout.arrange(5);
    expect(layout.count, 2, reason: 'five is refused');
    layout.arrange(4);
    expect(layout.count, 4);
    expect(layout.canAddPane, isFalse);
    layout.arrange(1);
    expect(layout.count, 1);
    expect(layout.canAddPane, isTrue);
  });

  test('a tab is moved only from a pane that is there', () {
    final layout = viewer()..arrange(2);
    final before = layout.snapshot();
    layout.move(3, 0, WorkspaceTab.explorer);
    expect(layout.snapshot(), before);
  });

  test('the main pane\'s last tab moved before another pane\'s tab takes '
      'its place there, and the panes are one', () {
    final layout = viewer()..arrange(2);
    layout.move(0, 1, WorkspaceTab.moves, before: WorkspaceTab.explorer);
    expect(layout.count, 1);
    expect(layout.openIn(0), [WorkspaceTab.moves, WorkspaceTab.explorer]);
  });

  test('the main pane\'s last tab is not closed with no pane to take its '
      'place; another pane\'s last tab is', () {
    final layout = viewer();
    expect(layout.canClose(0, WorkspaceTab.moves), isFalse);
    layout.arrange(2);
    expect(layout.canClose(1, WorkspaceTab.explorer), isTrue);
  });

  test('a lone pane with two tabs can close either', () {
    final layout = viewer()..open(0, WorkspaceTab.explorer);
    expect(layout.count, 1);
    expect(layout.canClose(0, WorkspaceTab.explorer), isTrue);
    expect(layout.canClose(0, WorkspaceTab.moves), isTrue);
  });

  test('the main pane\'s last tab goes where it is dropped among the tabs '
      'of the pane it joins', () {
    final layout = viewer()..arrange(2);
    layout.show(1, WorkspaceTab.filter);
    expect(layout.openIn(1), [WorkspaceTab.explorer, WorkspaceTab.filter]);
    layout.move(0, 1, WorkspaceTab.moves, before: WorkspaceTab.filter);
    expect(layout.count, 1);
    expect(layout.openIn(0), [
      WorkspaceTab.explorer,
      WorkspaceTab.moves,
      WorkspaceTab.filter,
    ]);
  });
}
