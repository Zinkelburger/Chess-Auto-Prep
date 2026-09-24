import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:chess_auto_prep/v2/storage/section_reference_check.dart';
import 'package:flutter_test/flutter_test.dart';

const path = '/Documents/repertoires/Course/Main.pgn';
const rename = SectionRename(path: path, from: 'A', to: 'B');

String game(String? section, {String moves = '1. e4 *'}) =>
    '${const PgnTag('Event', 'Line').text}\n'
    '${section == null ? '' : '${PgnTag('ChapterName', section).text}\n'}'
    '\n$moves\n\n';
String file(List<String?> sections) => sections.map(game).join();

EditScope edited(
  int count, {
  int appended = 0,
  List<SectionRename> changes = const [rename],
}) => GamesEdited(
  GamesWritten(
    rewritten: {for (var i = 0; i < count; i++) i},
    appended: appended,
  ),
  references: ReferenceChanges(changes),
);

String? problem(String before, String after, EditScope scope) =>
    sectionReferenceProblem(
      documentPath: path,
      before: before,
      after: after,
      scope: scope,
    );

void main() {
  test('a pure section rename preserves other named and unnamed games', () {
    expect(
      problem(
        file(['A', 'X', 'A', null]),
        file(['B', 'X', 'B', null]),
        edited(4),
      ),
      isNull,
    );
  });

  test('normal edits alongside the rename retain section provenance', () {
    expect(
      problem(
        game('A') + game('X'),
        game('B', moves: '1. d4 *') + game('X', moves: '1. c4 *'),
        edited(2),
      ),
      isNull,
    );
  });

  test('coalesced section names apply sequentially', () {
    expect(
      problem(
        file(['A', 'X']),
        file(['C', 'X']),
        edited(
          2,
          changes: [
            rename,
            const SectionRename(path: path, from: 'B', to: 'C'),
          ],
        ),
      ),
      isNull,
    );
  });

  test('a roundtrip and an existing same-name no-op are valid', () {
    expect(
      problem(
        file(['A', 'X']),
        file(['A', 'X']),
        edited(
          2,
          changes: [
            rename,
            const SectionRename(path: path, from: 'B', to: 'A'),
          ],
        ),
      ),
      isNull,
    );
    expect(
      problem(
        file(['A']),
        file(['A']),
        edited(
          1,
          changes: [const SectionRename(path: path, from: 'A', to: 'A')],
        ),
      ),
      isNull,
    );
  });

  test(
    'declarative arrangement carries retained games through reorder and removal',
    () {
      final scope = GamesRearranged(
        GamesArranged(before: 3, order: [1, 0], rewritten: {0}),
        references: ReferenceChanges([rename]),
      );
      expect(problem(file(['A', 'X', 'A']), file(['X', 'B']), scope), isNull);
    },
  );

  test('a coalesced rename then deletion can remove every renamed game', () {
    final scope = GamesRearranged(
      GamesArranged(before: 2, order: [1]),
      references: ReferenceChanges([rename]),
    );
    expect(problem(file(['A', 'X']), file(['X']), scope), isNull);
  });

  test('declared new games can introduce sections or remain unnamed', () {
    expect(
      problem(file(['A']), file(['B', 'New', null]), edited(1, appended: 2)),
      isNull,
    );
    final scope = GamesRearranged(
      GamesArranged(before: 2, order: [null, 1, 0], rewritten: {0}),
      references: ReferenceChanges([rename]),
    );
    expect(problem(file(['A', 'X']), file(['New', 'X', 'B']), scope), isNull);
  });

  test(
    'header lexer handles whitespace, escaping, same-line tags and comments',
    () {
      final before =
          '[Event "Line"] [ChapterName " A "]\n\n1. e4 { [ChapterName "false"] } *\n';
      final after =
          '[Event "Line"] [ChapterName "Quote\\\"Name"]\n\n1. e4 { [ChapterName "false"] } *\n';
      expect(
        problem(
          before,
          after,
          edited(
            1,
            changes: [
              const SectionRename(path: path, from: 'A', to: 'Quote"Name'),
            ],
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'ordinary scopes without reference intent need no reference validation',
    () {
      expect(problem(file(['A']), file(['B']), const WholeDocument()), isNull);
    },
  );

  for (final sections in [
    ['A', 'X'],
    ['B', 'Changed'],
    ['B', null],
  ]) {
    test('false or unrelated section change is refused: $sections', () {
      expect(problem(file(['A', 'X']), file(sections), edited(2)), isNotNull);
    });
  }

  test('every retained source game must receive the rename', () {
    expect(problem(file(['A', 'A']), file(['B', 'A']), edited(2)), isNotNull);
  });

  test('a renamed source cannot survive as an appended game', () {
    expect(
      problem(file(['A']), file(['B', 'A']), edited(1, appended: 1)),
      isNotNull,
    );
  });

  test('a new game cannot resurrect an eliminated intermediate name', () {
    expect(
      problem(
        file(['A']),
        file(['C', 'B']),
        edited(
          1,
          appended: 1,
          changes: [
            rename,
            const SectionRename(path: path, from: 'B', to: 'C'),
          ],
        ),
      ),
      isNotNull,
    );
  });

  test('missing source and missing same-name source are refused', () {
    expect(problem(file(['X']), file(['X']), edited(1)), isNotNull);
    expect(
      problem(
        file(['X']),
        file(['X']),
        edited(
          1,
          changes: [const SectionRename(path: path, from: 'A', to: 'A')],
        ),
      ),
      isNotNull,
    );
  });

  test('target collision and blank target are refused', () {
    expect(problem(file(['A', 'B']), file(['B', 'B']), edited(2)), isNotNull);
    expect(
      problem(
        file(['A']),
        file([null]),
        edited(
          1,
          changes: [const SectionRename(path: path, from: 'A', to: ' ')],
        ),
      ),
      isNotNull,
    );
  });

  test('reference intent must name this document', () {
    expect(
      problem(
        file(['A']),
        file(['B']),
        edited(
          1,
          changes: [
            const SectionRename(path: '/other.pgn', from: 'A', to: 'B'),
          ],
        ),
      ),
      isNotNull,
    );
  });

  test('a section update must be declared as a rewritten game', () {
    final scope = GamesEdited(
      GamesWritten.nothing,
      references: ReferenceChanges([rename]),
    );
    expect(problem(file(['A']), file(['B']), scope), isNotNull);
  });

  test(
    'whole-document and restored scopes cannot authorize inferred lineage',
    () {
      final changes = ReferenceChanges([rename]);
      expect(
        problem(file(['A']), file(['B']), WholeDocument(references: changes)),
        isNotNull,
      );
      expect(
        problem(file(['A']), file(['B']), RestoredVersion(references: changes)),
        isNotNull,
      );
    },
  );

  test('an unchanged-order claim cannot silently stand for a reorder', () {
    expect(problem(file(['A', 'X']), file(['X', 'B']), edited(2)), isNotNull);
  });

  for (final order in [
    [0, 0],
    [2],
    [-1],
    [0],
  ]) {
    test('invalid arrangement provenance is refused: $order', () {
      final scope = GamesRearranged(
        GamesArranged(before: 2, order: order, rewritten: {0, 1}),
        references: ReferenceChanges([rename]),
      );
      expect(problem(file(['A', 'X']), file(['B', 'X']), scope), isNotNull);
    });
  }

  test('incorrect before count and undeclared additions are refused', () {
    final scope = GamesRearranged(
      GamesArranged(before: 1, order: [0, 1], rewritten: {0}),
      references: ReferenceChanges([rename]),
    );
    expect(problem(file(['A', 'X']), file(['B', 'X']), scope), isNotNull);
    expect(problem(file(['A']), file(['B', 'New']), edited(1)), isNotNull);
  });
}
