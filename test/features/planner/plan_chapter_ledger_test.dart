import 'package:chess_auto_prep/features/planner/controllers/plan_chapter_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

/// Book names by path key; anything unlisted is unnamed.
const _names = <String, String>{
  'd4 d5 c4': "Queen's Gambit",
  'd4 d5 c4 e6': "Queen's Gambit Declined",
  'd4 d5 c4 e6 Nc3': "Queen's Gambit Declined: 3.Nc3",
  'd4 d5 c4 e6 g3': 'Catalan',
  'd4 d5 c4 c6': 'Slav Defense',
  'd4 d5 c4 Nf6': "Queen's Gambit Declined: Marshall Defense",
};

void main() {
  PlanChapterLedger make({double chapterMass = 0.10}) => PlanChapterLedger(
    nameFor: (path) async => _names[path.join(' ')],
    chapterMass: chapterMass,
  );

  test('familyOf is the book name before its first colon', () {
    expect(
      PlanChapterLedger.familyOf("Queen's Gambit Declined: 3.Nc3"),
      "Queen's Gambit Declined",
    );
    expect(PlanChapterLedger.familyOf('Catalan'), 'Catalan');
    expect(PlanChapterLedger.familyOf(null), 'Repertoire');
    expect(PlanChapterLedger.familyOf(''), 'Repertoire');
  });

  test('the root opens a chapter named after its family', () async {
    final ledger = make();
    final root = await ledger.chapterFor(['d4', 'd5', 'c4']);
    expect(root.name, "Queen's Gambit");
    expect(root.moves, ['d4', 'd5', 'c4']);
    // Nothing built yet: not a chapter to show.
    expect(ledger.chapters, isEmpty);
    expect(
      identical(await ledger.chapterFor(['d4', 'd5', 'c4']), root),
      isTrue,
    );
  });

  test(
    'our choice into another family opens a chapter; same family stays',
    () async {
      final ledger = make();
      await ledger.chapterFor(['d4', 'd5', 'c4']);
      await ledger.assign(
        ['d4', 'd5', 'c4', 'e6'],
        parent: ['d4', 'd5', 'c4'],
        ourChoice: true,
        reach: 1.0,
      );
      await ledger.assign(
        ['d4', 'd5', 'c4', 'e6', 'Nc3'],
        parent: ['d4', 'd5', 'c4', 'e6'],
        ourChoice: false,
        reach: 0.5,
      );
      await ledger.cut(['d4', 'd5', 'c4', 'e6', 'Nc3'], reason: 'stop');
      final chapters = ledger.chapters;
      expect(chapters.map((c) => c.family), ["Queen's Gambit Declined"]);
      expect(chapters.single.points.single.moves, [
        'd4',
        'd5',
        'c4',
        'e6',
        'Nc3',
      ]);
    },
  );

  test('an opponent reply needs chapterMass to become a chapter', () async {
    final ledger = make(chapterMass: 0.10);
    await ledger.chapterFor(['d4', 'd5', 'c4', 'e6']);
    await ledger.assign(
      ['d4', 'd5', 'c4', 'e6', 'g3'],
      parent: ['d4', 'd5', 'c4', 'e6'],
      ourChoice: false,
      reach: 0.05,
    );
    await ledger.cut(['d4', 'd5', 'c4', 'e6', 'g3'], reason: 'thin');
    // Too light for a chapter of its own: the Catalan line stays in the QGD.
    expect(ledger.chapters.map((c) => c.family), ["Queen's Gambit Declined"]);

    final heavy = make(chapterMass: 0.10);
    await heavy.chapterFor(['d4', 'd5', 'c4', 'e6']);
    await heavy.assign(
      ['d4', 'd5', 'c4', 'e6', 'g3'],
      parent: ['d4', 'd5', 'c4', 'e6'],
      ourChoice: false,
      reach: 0.10,
    );
    await heavy.cut(['d4', 'd5', 'c4', 'e6', 'g3'], reason: 'stop');
    expect(heavy.chapters.map((c) => c.family), ['Catalan']);
  });

  test('finish drops empty chapters and tells same-named ones apart', () async {
    final ledger = make();
    await ledger.chapterFor(['d4', 'd5', 'c4']);
    for (final san in ['e6', 'Nf6']) {
      await ledger.assign(
        ['d4', 'd5', 'c4', san],
        parent: ['d4', 'd5', 'c4'],
        ourChoice: true,
        reach: 1.0,
      );
      await ledger.cut(['d4', 'd5', 'c4', san], reason: 'stop');
    }
    final chapters = ledger.finish();
    expect(chapters, hasLength(2));
    expect(chapters.map((c) => c.name).toSet(), hasLength(2));
    expect(
      chapters.every((c) => c.name.startsWith("Queen's Gambit Declined")),
      isTrue,
    );
    expect(chapters.where((c) => c.name.contains('e6')), hasLength(1));
    expect(chapters.where((c) => c.name.contains('Nf6')), hasLength(1));
  });

  test('a snapshot restores the ledger exactly', () async {
    final ledger = make();
    await ledger.chapterFor(['d4', 'd5', 'c4']);
    final before = ledger.snapshot();
    await ledger.assign(
      ['d4', 'd5', 'c4', 'c6'],
      parent: ['d4', 'd5', 'c4'],
      ourChoice: true,
      reach: 1.0,
    );
    await ledger.cut(['d4', 'd5', 'c4', 'c6'], reason: 'stop');
    expect(ledger.chapters.map((c) => c.family), ['Slav Defense']);

    ledger.restore(before);
    expect(ledger.chapters, isEmpty);
    // The Slav assignment is forgotten: cutting there opens a fresh chapter.
    await ledger.cut(['d4', 'd5', 'c4', 'c6'], reason: 'stop');
    expect(ledger.chapters.map((c) => c.family), ['Slav Defense']);
    expect(ledger.chapters.single.moves, ['d4', 'd5', 'c4', 'c6']);
  });
}
