// Lines dragged out of a chapter that no longer has them.

import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

void main() {
  const twoLines = '''
// Main
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *
''';
  const sidelines = '''
// Sidelines
// Color: White

[Event "Catalan"]
[Result "*"]

1. d4 d5 2. c4 e6 3. g3 *
''';

  test('a line index past the end of the chapter moves nothing', () async {
    final fixture = await openLibrary([
      folder('KID', ['Main', 'Sidelines']),
    ]);
    addTearDown(fixture.dispose);
    fixture.store.documents[ref('KID', 'Main')] = Opened(
      twoLines,
      scriptedRevision(twoLines),
    );
    fixture.store.documents[ref('KID', 'Sidelines')] = Opened(
      sidelines,
      scriptedRevision(sidelines),
    );
    await fixture.session.open(ref('KID', 'Main'));

    // A drag picked up the third line of a chapter that now has two.
    expect(
      await fixture.library.moveLines(games: {2}, to: ref('KID', 'Sidelines')),
      isA<LibraryDone>(),
    );

    expect(fixture.textAt('/repertoires/KID/Sidelines.pgn'), sidelines);
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), twoLines);
    expect(fixture.session.chapter!.lines.length, 2);
  });
}
