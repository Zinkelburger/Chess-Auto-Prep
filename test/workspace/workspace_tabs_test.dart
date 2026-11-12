import 'package:chess_auto_prep/ui/app_keys.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the builder offers no tab that belongs to another mode', () {
    final offered = {for (final tab in newWorkspaceTabs().tabs) tab.id};
    expect(
      offered.intersection({
        WorkspaceTab.puzzle,
        WorkspaceTab.source,
        WorkspaceTab.book,
        WorkspaceTab.filter,
        WorkspaceTab.solitaire,
        WorkspaceTab.player,
        WorkspaceTab.playerBook,
      }),
      isEmpty,
    );
    expect(offered, containsAll([WorkspaceTab.moves, WorkspaceTab.search]));
  });

  test('Train, the puzzle and the game are always there in their modes', () {
    for (final (tabs, pinned) in [
      (trainerTabs(), WorkspaceTab.train),
      (puzzleTabs(), WorkspaceTab.puzzle),
      (bookTabs(), WorkspaceTab.moves),
    ]) {
      expect(tabs.isOpen(pinned), isTrue);
      tabs.close(pinned);
      expect(tabs.isOpen(pinned), isTrue, reason: '$pinned cannot be closed');
    }
  });

  test('the menu shows or closes each tab that can go, by name, with the '
      'close key beside the tab that is up', () {
    final tabs = trainerTabs()..show(WorkspaceTab.explorer);
    final actions = tabActions(tabs);
    final labels = [for (final action in actions) action.label];
    expect(labels, isNot(contains('Close Train')));
    expect(labels, isNot(contains('Show Train')));
    expect(labels, containsAll(['Show Analysis', 'Close Moves']));
    final explorer = actions.firstWhere((a) => a.label == 'Close Explorer');
    expect(explorer.shortcut, AppKey.closeTab.label);
    final moves = actions.firstWhere((a) => a.label == 'Close Moves');
    expect(moves.shortcut, isNull);
  });

  test('Next tab needs a second tab open', () {
    final one = readingTabs()..close(WorkspaceTab.explorer);
    one.close(WorkspaceTab.review);
    expect(one.open, [WorkspaceTab.moves]);
    expect(tabActions(one).last.run, isNull);
    final two = readingTabs()..close(WorkspaceTab.review);
    expect(two.open, hasLength(2));
    expect(tabActions(two).last.label, 'Next tab');
    expect(tabActions(two).last.run, isNotNull);
  });
}
