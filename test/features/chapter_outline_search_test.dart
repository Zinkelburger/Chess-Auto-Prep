// The outline's search and position filter, in the small: a search that
// has gone through every chapter says it is done, the same words typed again
// tell nobody, and At this position reads a line's main moves, not a
// variation inside it.
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/features/library/chapter_outline.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

const _withVariation = '''
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 (1... Nf6 2. c4) 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 2. c4 g6 *
''';

/// The middle game starts from a set-up position; the others from the
/// start, where the chapter does.
const _otherStart = '''
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 *

[Event "Set up"]
[Result "*"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]
[SetUp "1"]

1... e5 *

[Event "Open"]
[Result "*"]

1. e4 e5 *
''';

void main() {
  late LibraryFixture fixture;
  late ChapterOutline outline;

  Future<void> open() async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main', 'Sidelines']),
      ],
      text: _withVariation,
      open: ref('KID', 'Main'),
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
  }

  test('a search that has gone through every chapter is done', () async {
    await open();
    outline.search('indian');
    await pumpEventQueue();
    await pumpEventQueue();
    expect(outline.searching, isFalse);
  });

  test('the same words typed again tell nobody', () async {
    await open();
    var told = 0;
    outline.addListener(() => told++);
    outline.search('ind');
    final once = told;
    expect(once, greaterThan(0));
    outline.search('ind');
    expect(told, once);
  });

  test('a line from another start never holds the cursor', () async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main']),
      ],
      text: _otherStart,
      open: ref('KID', 'Main'),
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
    final tree = fixture.session.tree!;
    fixture.session.cursor.goTo(pathOfSans(tree, ['e4', 'e5'])!);
    expect(
      [
        outline.isCurrent(0).value,
        outline.isCurrent(1).value,
        outline.isCurrent(2).value,
      ],
      [false, false, true],
    );
  });

  test('At this position reads each line\'s main moves', () async {
    await open();
    final tree = fixture.session.tree!;
    fixture.session.cursor.goTo(pathOfSans(tree, ['d4', 'Nf6'])!);
    outline.showAtPosition(true);
    expect(outline.lines.map((line) => line.name), ['Indian']);
  });
}
