import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/app/layout_memory.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/action_layout.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';
import '../support/session_fixture.dart';

void main() {
  test('trainer restores Analysis beside Train', () async {
    final fixture = await openSession('[Result "*"]\n\n1. e4 *');
    addTearDown(fixture.dispose);
    final settings = SettingsStore();
    addTearDown(settings.dispose);
    final explorer = explorerOver(fixture.session, settings: settings);
    addTearDown(explorer.dispose);
    final layout = ActionLayout(
      trainerTabs(),
      explorer,
      opensBeside: true,
      analysisInPanes: true,
    );
    addTearDown(layout.dispose);
    layout.reveal(WorkspaceTab.analysis);
    final saved = layout.snapshot();
    final restored = ActionLayout(
      trainerTabs(),
      explorer,
      opensBeside: true,
      analysisInPanes: true,
    );
    addTearDown(restored.dispose);
    expect(restored.restore(saved), isTrue);
    expect(restored.count, 2);
    expect(restored.snapshot(), saved);
  });

  test(
    'files and modes retain independent layouts, reset and survive immediate exit',
    () async {
      final folder = await Directory.systemTemp.createTemp('layout-memory-');
      addTearDown(() => folder.delete(recursive: true));
      final fixture = await openSession('[Result "*"]\n\n1. e4 *');
      addTearDown(fixture.dispose);
      final pending = PendingWrites();
      final settings = SettingsStore(support: folder)..pendingWrites = pending;
      addTearDown(settings.dispose);
      final explorer = explorerOver(fixture.session, settings: settings);
      addTearDown(explorer.dispose);
      final builder = ActionLayout(newWorkspaceTabs(), explorer)
        ..startBuilding();
      final viewer = ActionLayout(viewerTabs(), explorer);
      addTearDown(builder.dispose);
      addTearDown(viewer.dispose);
      final memory = LayoutMemory(settings, {
        Mode.repertoires: builder,
        Mode.pgnViewer: viewer,
      });
      addTearDown(memory.dispose);
      memory.select(Mode.repertoires, '/a.pgn', builder);
      builder.resizeBoard(0.6);
      builder.book!.value = true;
      builder.reveal(WorkspaceTab.train);
      final original = builder.snapshot();
      memory.select(Mode.repertoires, '/b.pgn', builder);
      expect(builder.boardFraction, 0.4);
      expect(builder.book!.value, isFalse);
      builder.resizeBoard(0.3);
      memory.select(Mode.pgnViewer, '/a.pgn', viewer);
      viewer.resizeBoard(0.5);
      memory.select(Mode.repertoires, '/a.pgn', builder);
      expect(builder.snapshot(), original);
      memory.reset();
      expect(builder.boardFraction, 0.4);
      expect(builder.book!.value, isFalse);
      builder.resizeBoard(0.55);
      expect(await pending.settle(), isNull); // Includes the 250 ms debounce.
      final reopened = SettingsStore(support: folder);
      addTearDown(reopened.dispose);
      await reopened.load();
      final saved = reopened
          .value
          .workspaceLayouts[jsonEncode(['repertoires', '/a.pgn'])]!;
      expect((jsonDecode(saved) as Map)['board'], 0.55);
    },
  );

  test(
    'corrupt layout metadata cannot hide the primary pane or throw',
    () async {
      final fixture = await openSession('[Result "*"]\n\n1. e4 *');
      addTearDown(fixture.dispose);
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final explorer = explorerOver(fixture.session, settings: settings);
      addTearDown(explorer.dispose);
      final layout = ActionLayout(newWorkspaceTabs(), explorer);
      addTearDown(layout.dispose);
      final original = layout.snapshot();
      final data = jsonDecode(original) as Map<String, Object?>;
      data['active'] = 0.0;
      expect(layout.restore(jsonEncode(data)), isTrue);
      expect(layout.active, 0);
      data['tree'] = 1;
      final panes = data['panes'] as Map;
      panes['1'] = panes['0'];
      expect(layout.restore(jsonEncode(data)), isFalse);
      expect(layout.snapshot(), original);
      expect(layout.restore('{broken'), isFalse);
      layout.split(0, WorkspaceTab.explorer, PaneSplitDirection.right);
      for (final share in [0.1, 0.9]) {
        layout.resize(layout.root as ActionPaneSplit, share);
        final saved = layout.snapshot();
        expect(layout.restore(saved), isTrue);
        expect((layout.root as ActionPaneSplit).share, share);
      }
    },
  );
}
