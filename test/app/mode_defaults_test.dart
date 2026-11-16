// What a mode is unless it says otherwise, seen in Databases, which says
// nothing: a game read, never written; the whole board; the builder and a
// new analysis tab offered; the arrow keys left to the file; a tab picked
// from `+` joining the pane it was picked in; and the engine kept to one
// pane.
import 'package:chess_auto_prep/app/database_view.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late DatabasesView view;
  setUp(() {
    w = WindowFixture();
    view = DatabasesView(w.parts.workspace, w.parts.databases, w.requests);
    addTearDown(view.dispose);
  });
  tearDown(() => w.dispose());

  test('a game is read, not written, on the whole board', () {
    expect(view.editSwitch, isFalse);
    expect(view.startsEditing, isFalse);
    expect(view.studyTools, isFalse);
    expect(view.quietBoard, isFalse);
  });

  test('the builder and a new analysis tab are offered', () {
    expect(view.offersBuilder, isTrue);
    expect(view.offersNewAnalysis, isTrue);
  });

  test('the arrow keys and Esc are left to the window', () {
    expect(view.walk(1), isFalse);
    expect(view.walk(-1), isFalse);
    expect(view.leave(), isFalse);
  });

  test('a tab picked from + joins the one pane', () {
    view.layout.open(0, WorkspaceTab.notes);
    expect(view.layout.count, 1);
    expect(view.tabs.selected, WorkspaceTab.notes);
  });

  test('the engine is not split into a pane of its own', () {
    expect(view.layout.canSplit(WorkspaceTab.analysis), isFalse);
    expect(view.layout.canSplit(WorkspaceTab.notes), isTrue);
  });
}
