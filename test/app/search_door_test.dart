// The Actions entry that starts a search: the Search tab comes up and the
// search starts, afresh when nothing is saved for the board; a mode
// without a Search tab, or a search that cannot start, leaves everything
// as it was; and what refused the search is said in the bar.
import 'package:chess_auto_prep/app/search_door.dart';
import 'package:chess_auto_prep/ui/pane_tabs.dart';
import 'package:chess_auto_prep/workspace/action_layout.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/search/fill_states.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late SearchDoor door;
  setUp(() async {
    w = WindowFixture();
    door = SearchDoor(
      fill: w.parts.workspace.fill,
      settings: w.settings,
      requests: w.requests,
    );
    await w.requests.open(kidMain);
    w.requests.say('Earlier');
  });
  tearDown(() {
    w.parts.workspace.fill.cancel();
    w.dispose();
  });

  /// [tabs] on their Moves tab.
  ActionLayout layout(PaneTabs<WorkspaceTab> tabs) {
    final layout = ActionLayout(
      tabs..show(WorkspaceTab.moves),
      w.parts.workspace.explorer,
    );
    addTearDown(layout.dispose);
    return layout;
  }

  test('brings the Search tab up and starts afresh, saying nothing', () async {
    final builder = layout(newWorkspaceTabs());
    await door.search(builder);
    expect(builder.pane(0).selected, WorkspaceTab.search);
    expect(w.parts.workspace.fill.state, isNot(isA<FillIdle>()));
    expect(w.requests.status, 'Earlier');
  });

  test('starts nothing in a mode without a Search tab', () async {
    final reading = layout(readingTabs());
    await door.search(reading);
    expect(reading.pane(0).selected, WorkspaceTab.moves);
    expect(w.parts.workspace.fill.state, isA<FillIdle>());
    expect(w.requests.status, 'Earlier');
  });

  test('starts nothing, nor shows the tab, when no search can start', () async {
    final jobs = w.parts.workspace.jobs!;
    final review = Object();
    jobs.take(review, 'Reviewing', kind: EngineJobKind.review);
    addTearDown(() => jobs.release(review));
    final builder = layout(newWorkspaceTabs());
    await door.search(builder);
    expect(builder.pane(0).selected, WorkspaceTab.moves);
    expect(w.parts.workspace.fill.state, isA<FillIdle>());
    expect(w.requests.status, 'Earlier');
  });

  test('says why when the board moves while the search is read', () async {
    final searching = door.search(layout(newWorkspaceTabs()));
    w.session.cursor.forward();
    await searching;
    expect(w.requests.status, 'The board changed while loading the search.');
  });
}
