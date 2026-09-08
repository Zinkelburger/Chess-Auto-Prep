import 'package:chess_auto_prep/core/pgn/pgn_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main game stays open and next visits only opened tabs', () {
    final tabs = PgnWorkspace();
    tabs.close(0);
    expect(tabs.openTabs, [0]);
    tabs.index = PgnWorkspace.analysis;
    tabs.next();
    expect(tabs.index, 0);
    tabs.next();
    expect(tabs.index, PgnWorkspace.analysis);
    tabs.index = PgnWorkspace.analysis;
    expect(tabs.openTabs, [0, 3]);
    tabs.close(3);
    expect(tabs.openTabs, [0]);
    expect(tabs.index, 0);
  });
  test('old tree notifications cannot undo a tab switch or close', () {
    final tabs = PgnWorkspace();
    var treeVisible = false;
    tabs.addListener(() {
      // Stopping playback notifies before the board's tree flag is changed.
      tabs.synchronizeTree(treeVisible);
      treeVisible = tabs.index == PgnWorkspace.tree;
      tabs.synchronizeTree(treeVisible);
    });
    tabs.index = PgnWorkspace.tree;
    tabs.index = PgnWorkspace.analysis;
    expect(tabs.index, PgnWorkspace.analysis);
    expect(treeVisible, isFalse);
    tabs.index = PgnWorkspace.tree;
    tabs.close(PgnWorkspace.tree);
    expect(tabs.index, 0);
    expect(treeVisible, isFalse);
  });
  test(
    'closing background and reordered reference tabs preserves selection',
    () {
      final tabs = PgnWorkspace();
      final a = tabs.add('A');
      final b = tabs.add('B');
      tabs.index = a;
      tabs.index = b;
      tabs.move(b, a);
      expect(tabs.openTabs, [0, b, a]);
      tabs.close(a);
      expect(tabs.index, b);
      tabs.close(b);
      expect(tabs.index, 0);
      expect(tabs.titles.containsKey(b), isFalse);
    },
  );
}
