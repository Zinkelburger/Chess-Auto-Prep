// The window's columns: the list and the workspace to start with, the
// outline beside them for a whole-file chapter in the builder, the two
// left columns folded into one below the side-by-side width, ↓ and ↑
// walking the Positions only while they are in front of the user, and
// nothing done once the window is gone.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/window_columns.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/board/board_claim.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late WindowColumns columns;
  var disposed = false;

  setUp(() {
    w = WindowFixture();
    disposed = false;
    columns = WindowColumns(
      requests: w.requests,
      workspace: w.parts.workspace,
      lesson: ValueNotifier<BoardClaim?>(null),
    );
  });
  tearDown(() {
    if (!disposed) columns.dispose();
    w.dispose();
  });

  List<WindowPane?> panes() => [
    for (final area in columns.controller.areas) area.data as WindowPane?,
  ];

  test('start as the list and the workspace', () {
    columns.arrange();
    expect(panes(), [WindowPane.list, WindowPane.workspace]);
  });

  test('a whole-file chapter in the builder brings the outline beside the '
      'list', () async {
    w.requests.switchTo(Mode.repertoires);
    await w.requests.open(kidMain);
    columns.arrangeForMode();
    expect(panes(), [
      WindowPane.list,
      WindowPane.outline,
      WindowPane.workspace,
    ]);
  });

  test('fold into one column only below the side-by-side width', () {
    columns.fit(navigationSideBySideMinWidth, 1);
    expect(columns.compact, isFalse);
    columns.fit(navigationSideBySideMinWidth - 1, 1);
    expect(columns.compact, isTrue);
  });

  group('↓ and ↑ walk the Positions', () {
    test('not while the list column shows the mode\'s own list', () {
      expect(columns.walksPositions, isFalse);
    });

    test('while they are side by side with the rest', () {
      columns.showPositions();
      expect(columns.walksPositions, isTrue);
    });

    test('in a folded column, only on their page', () {
      columns
        ..showPositions()
        ..compact = true
        ..outlineShown = true;
      expect(columns.walksPositions, isTrue, reason: 'page 0 is theirs');
      columns.page = 1;
      expect(columns.walksPositions, isFalse);
      columns.outlineShown = false;
      expect(columns.walksPositions, isTrue, reason: 'no page to share');
    });

    test('not while the list column is hidden', () {
      columns
        ..showPositions()
        ..toggleList();
      expect(columns.walksPositions, isFalse);
    });
  });

  test('once taken down, hiding the list does nothing', () {
    columns.dispose();
    disposed = true;
    expect(columns.toggleList, returnsNormally);
    expect(columns.listShown, isTrue);
  });
}
