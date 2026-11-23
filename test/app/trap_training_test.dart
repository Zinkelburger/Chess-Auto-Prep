import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/features/trainer/lesson.dart';
import 'package:chess_auto_prep/features/trainer/trainer_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

/// A search in which the likely reply f6 to e4 loses.
OurNode trapTree(Fen root) => OurNode.over(
  fen: root,
  evalForUs: const Eval(30),
  candidates: [
    CandidateMove(
      move: const MoveRef(uci: 'e2e4', san: 'e4'),
      child: OpponentNode.over(
        fen: lineTree(root, const ['e4']).children.single.fen,
        evalForUs: const Eval(30),
        replies: [
          ReplyMove(
            move: const MoveRef(uci: 'e7e5', san: 'e5'),
            probability: 0.6,
            child: HorizonNode(
              fen: lineTree(root, const ['e4', 'e5']).mainLine.last.fen,
              evalForUs: const Eval(0),
            ),
          ),
          ReplyMove(
            move: const MoveRef(uci: 'f7f6', san: 'f6'),
            probability: 0.4,
            child: HorizonNode(
              fen: lineTree(root, const ['e4', 'f6']).mainLine.last.fen,
              evalForUs: const Eval(250),
            ),
          ),
        ],
      ),
    ),
  ],
);

String chapterWith(String moves) =>
    '// Main\n// Color: White\n\n[Event "Line"]\n[Result "*"]\n\n$moves *\n';

void main() {
  late WindowFixture w;
  final main = ref('KID', 'Main');
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Repertoires kidWith(Iterable<ChapterRef> others) => Repertoires([
    folder('benko', ['Main']),
    RepertoireFolder(
      name: 'KID',
      path: '/repertoires/KID',
      modified: DateTime.now(),
      chapters: [main, ...others],
    ),
  ]);

  Future<void> openWith(
    WidgetTester tester,
    String text, {
    bool listed = true,
    ChapterRef? source,
  }) async {
    final chapter = source ?? main;
    w.store.documents[chapter.wholeFile] = Opened(text, scriptedRevision(text));
    if (listed) w.chapterFiles.listing = kidWith(const []);
    await w.library.refresh();
    await w.session.open(chapter);
    final root = w.session.chapter!.tree.rootFen;
    await w.parts.workspace.finds.record(
      trapTree(root),
      rootFen: root,
      prefix: const [],
      side: Side.white,
      elo: 1800,
    );
    await w.pumpShell(tester);
    await choosePanel(tester, 'Positions');
  }

  /// The Positions list the open chapter's finds by default; a trap the
  /// chapter never reaches shows once `This chapter` is turned off.
  Future<void> listEveryFind(WidgetTester tester) async {
    expect(find.textContaining('f6?', findRichText: true), findsNothing);
    expect(find.text('None in this chapter.'), findsOneWidget);
    await tester.tap(find.text('This chapter'));
    await tester.pumpAndSettle();
  }

  Future<void> trainTheTrap(WidgetTester tester) async {
    final row = find.ancestor(
      of: find.textContaining('f6?', findRichText: true),
      matching: find.byType(InkWell),
    );
    await tester.tap(
      find.descendant(of: row.first, matching: find.byTooltip('Actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Train this line'));
    await tester.pumpAndSettle();
  }

  testWidgets('a board that is neither the chapter nor a find\'s line '
      'lists every find, with no This chapter', (tester) async {
    await openWith(tester, chapterWith('1. d4 d5'));
    expect(find.text('None in this chapter.'), findsOneWidget);
    await w.session.showAnalysisBoard(analysisBoard(side: Side.white));
    await tester.pumpAndSettle();
    expect(find.text('This chapter'), findsNothing);
    expect(find.text('None in this chapter.'), findsNothing);
    expect(find.textContaining('f6?', findRichText: true), findsOneWidget);
  });

  testWidgets('a trap the chapter plays is trained there at once', (
    tester,
  ) async {
    await openWith(tester, chapterWith('1. e4 f6 2. d4'));
    await trainTheTrap(tester);

    expect(find.text('Add and train'), findsNothing);
    expect(w.requests.mode, Mode.repertoires);
    expect(w.session.source, main);
    expect(w.lineTrainer.lesson, isNotNull);
  });

  testWidgets('training a trap credits only the open course chapter', (
    tester,
  ) async {
    const path = '/repertoires/KID/Course.pgn';
    final first = ChapterRef.at(path, section: 'A');
    final second = ChapterRef.at(path, section: 'B');
    const course =
        '// Color: White\n\n'
        '[Event "Continuation"]\n[ChapterName "A"]\n[LineID "line-a"]\n\n'
        '1. e4 f6 2. d4 *\n\n'
        '[Event "Short line"]\n[ChapterName "B"]\n[LineID "line-b"]\n\n'
        '1. e4 f6 *\n';
    w.chapterFiles.listing = kidWith([first, second]);
    await openWith(tester, course, listed: false, source: first);
    w.lineTrainer.setScope(TrainScope.repertoire);
    await tester.pumpAndSettle();
    await trainTheTrap(tester);

    final lesson = w.lineTrainer.lesson!;
    const expected = (source: path, id: 'line-a');
    expect(lesson.line.key, expected);

    const answers = ['e2e4', 'd2d4'];
    final reply = Duration(milliseconds: lesson.options.replyMillis);
    for (final move in answers) {
      lesson.next();
      lesson.play(move);
      await tester.pump(reply * 2);
    }
    for (final move in answers) {
      lesson.play(move);
      await tester.pump(reply);
    }
    await tester.pump(finishedPause);
    expect(w.progress.reviews.keys, [expected]);
    expect(w.progress.reviews[expected]!.lastRating, 'good');
  });

  testWidgets('a course opened by path trains its sole named chapter', (
    tester,
  ) async {
    const path = '/repertoires/KID/Course.pgn';
    const course =
        '// Color: White\n\n'
        '[Event "Continuation"]\n[ChapterName "A"]\n[LineID "long"]\n\n'
        '1. e4 f6 2. d4 *\n\n'
        '[Event "Trap"]\n[ChapterName "A"]\n[LineID "short"]\n\n'
        '1. e4 f6 *\n';
    w.chapterFiles.listing = kidWith([ChapterRef.at(path, section: 'A')]);
    await openWith(tester, course, listed: false, source: ChapterRef.at(path));
    w.lineTrainer.setScope(TrainScope.repertoire);
    await tester.pumpAndSettle();
    await trainTheTrap(tester);

    expect(w.lineTrainer.lesson?.line.key, (source: path, id: 'short'));
  });
  for (final (description, moves, paused) in [
    ('a variation', '1. e4 e5 (1... f6)', false),
    ('a paused main line', '1. e4 f6', true),
  ]) {
    testWidgets('a trap held as $description opens its drillable sibling', (
      tester,
    ) async {
      final examples = ChapterRef.at(main.path, section: 'Examples');
      final traps = ChapterRef.at(main.path, section: 'Traps');
      w.chapterFiles.listing = kidWith([examples, traps]);
      if (paused) {
        final key = (source: main.path, id: 'open');
        w.progress.reviews[key] = Review(
          key: key,
          lineName: 'Open',
          excluded: true,
        );
      }
      await openWith(tester, '''
// Color: White

[Event "Open"]
[LineID "open"]

$moves *

[Event "Model game"]
[ChapterName "Examples"]
[Result "1-0"]

1. e4 f6 2. d4 d5 1-0

[Event "Trap line"]
[ChapterName "Traps"]
[LineID "trap"]

1. e4 f6 2. d4 *
''', listed: false);
      w.lineTrainer.setScope(TrainScope.repertoire);
      await tester.pumpAndSettle();
      await trainTheTrap(tester);

      expect(w.session.source, traps);
      expect(w.lineTrainer.lesson!.line.key, (source: main.path, id: 'trap'));
    });
  }

  testWidgets('a trap no chapter plays goes into the draft, asked first, '
      'and is trained there', (tester) async {
    await openWith(tester, chapterWith('1. d4 d5'));
    await listEveryFind(tester);
    await trainTheTrap(tester);

    expect(find.textContaining('Main (draft)'), findsOneWidget);
    await tester.tap(find.text('Add and train'));
    await tester.pumpAndSettle();

    final draft = ChapterRef.at('/repertoires/KID/Main (draft).pgn');
    expect(w.session.source, draft);
    expect(readHeading(w.session.chapter!.preamble).draft, isTrue);
    expect(w.requests.status, isNull);
    expect(w.lineTrainer.state, isA<TrainerReady>());
    expect(w.lineTrainer.lesson, isNotNull);
    await w.saver.flush();
    expect((w.store.documents[draft]! as Opened).text, contains('1. e4 f6'));
  });

  for (final (description, setup) in [
    (
      'imported PGN setup position',
      const Fen('rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2'),
    ),
    ('imported move counters', Fen('${Fen.initial.position} 8 17')),
  ]) {
    testWidgets('a new trap draft starts from the $description and is '
        'trained from there', (tester) async {
      await openWith(
        tester,
        '// Color: White\n\n[Event "Imported"]\n[Result "*"]\n'
        '[SetUp "1"]\n[FEN "${setup.value}"]\n\n${setup.fullMove}. c4 *\n',
      );
      await listEveryFind(tester);
      await trainTheTrap(tester);
      await tester.tap(find.text('Add and train'));
      await tester.pumpAndSettle();
      await w.saver.flush();

      final draft = ChapterRef.at('/repertoires/KID/Main (draft).pgn');
      final saved = await w.library.chapterForSearch(draft);
      expect(saved?.tree.rootFen, setup);
      expect(mainlineSans(saved!.tree), ['e4', 'f6']);
      expect(saved.lines.single.nameAt(0), 'Repertoire Line');
      expect(w.lineTrainer.lesson?.line.key.id, trainedIdsOf(saved).single);
      expect(w.lineTrainer.lesson?.line.start, setup);
    });
  }

  testWidgets('a trap no chapter plays, the draft declined, goes nowhere', (
    tester,
  ) async {
    await openWith(tester, chapterWith('1. d4 d5'));
    await listEveryFind(tester);
    await trainTheTrap(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(w.session.source, main);
    expect(
      w.store.documents.keys.where((ref) => ref.path.contains('draft')),
      isEmpty,
    );
    expect(w.lineTrainer.lesson, isNull);
  });

  testWidgets('a trap goes into the draft already beside the chapter, as one '
      'edit', (tester) async {
    const draftText =
        '// Main (draft 2)\n// Draft\n// Color: White\n\n'
        '[Event "Old"]\n[Result "*"]\n\n1. c4 *\n';
    const draft = ChapterRef(
      repertoire: 'KID',
      name: 'Main (draft 2)',
      path: '/repertoires/KID/Main (draft 2).pgn',
      heading: ChapterHeading(draft: true),
    );
    w.store.documents[draft] = Opened(draftText, scriptedRevision(draftText));
    w.store.documents[main] = Opened(
      chapterWith('1. d4 d5'),
      scriptedRevision(chapterWith('1. d4 d5')),
    );
    w.chapterFiles.listing = Repertoires([
      folder('benko', ['Main']),
      RepertoireFolder(
        name: 'KID',
        path: '/repertoires/KID',
        modified: DateTime.now(),
        chapters: [ref('KID', 'Main'), draft],
      ),
    ]);
    await w.library.refresh();
    await w.session.open(main);
    await w.parts.workspace.finds.record(
      trapTree(Fen.initial),
      rootFen: Fen.initial,
      prefix: const [],
      side: Side.white,
      elo: 1800,
    );
    await w.pumpShell(tester);
    await choosePanel(tester, 'Positions');
    await listEveryFind(tester);
    await trainTheTrap(tester);

    expect(find.text('Add this line to “Main (draft 2)”?'), findsOneWidget);
    await tester.tap(find.text('Add and train'));
    await tester.pumpAndSettle();

    expect(w.session.source?.path, draft.path);
    expect(w.lineTrainer.lesson, isNotNull);
    await w.saver.flush();
    final text = (w.store.documents[draft]! as Opened).text;
    expect(text, contains('1. c4'), reason: 'what the draft had is kept');
    expect(text, contains('1. e4 f6'));
    expect(
      w.store.documents.keys.where((k) => k.path.contains('(draft)')),
      isEmpty,
      reason: 'no second draft is made',
    );
  });

  /// Main open with 1.d4 d5, beside [others] in KID, whose texts are given.
  Future<void> openBeside(
    WidgetTester tester,
    Map<ChapterRef, String> others,
  ) async {
    for (final MapEntry(key: other, value: text) in others.entries) {
      w.store.documents[other] = Opened(text, scriptedRevision(text));
    }
    w.chapterFiles.listing = kidWith(others.keys);
    await openWith(tester, chapterWith('1. d4 d5'), listed: false);
  }

  String draftText(String name, String color) =>
      '// $name\n// Draft\n// Color: $color\n\n'
      '[Event "Old"]\n[Result "*"]\n\n1. c4 *\n';

  ChapterRef inKid(String name, {bool draft = true}) => ChapterRef(
    repertoire: 'KID',
    name: name,
    path: '/repertoires/KID/$name.pgn',
    heading: ChapterHeading(draft: draft),
  );

  testWidgets('a file already called Main (draft) that is no draft: the '
      'question names Main (draft 2), and the line goes there', (tester) async {
    final taken = inKid('Main (draft)', draft: false);
    await openBeside(tester, {taken: chapterWith('1. c4')});
    await listEveryFind(tester);
    await trainTheTrap(tester);

    expect(find.text('Add this line to “Main (draft 2)”?'), findsOneWidget);
    await tester.tap(find.text('Add and train'));
    await tester.pumpAndSettle();

    final draft = ChapterRef.at('/repertoires/KID/Main (draft 2).pgn');
    expect(w.session.source, draft);
    await w.saver.flush();
    expect((w.store.documents[draft]! as Opened).text, contains('1. e4 f6'));
    expect(
      (w.store.documents[taken]! as Opened).text,
      chapterWith('1. c4'),
      reason: 'the file in the way is left alone',
    );
  });

  testWidgets('Add and train preserves a regular chapter that replaced the '
      'listed draft', (tester) async {
    final draft = inKid('Main (draft)');
    await openBeside(tester, {draft: draftText(draft.name, 'White')});
    await listEveryFind(tester);
    await trainTheTrap(tester);
    expect(find.text('Add this line to “Main (draft)”?'), findsOneWidget);

    // A sync replaces the file while the player is reading the question.
    final replacement = chapterWith('1. Nf3 d5');
    w.store.documents[draft] = Opened(
      replacement,
      scriptedRevision(replacement),
    );
    await tester.tap(find.text('Add and train'));
    await tester.pumpAndSettle();
    await w.saver.flush();

    expect((w.store.documents[draft]! as Opened).text, replacement);
  });

  testWidgets('a draft beside the chapter for the other side is passed over', (
    tester,
  ) async {
    final black = inKid('Main (draft)');
    await openBeside(tester, {black: draftText('Main (draft)', 'Black')});
    await listEveryFind(tester);
    await trainTheTrap(tester);

    expect(find.text('Add this line to “Main (draft 2)”?'), findsOneWidget);
    await tester.tap(find.text('Add and train'));
    await tester.pumpAndSettle();

    expect(w.session.source?.path, '/repertoires/KID/Main (draft 2).pgn');
    expect(
      (w.store.documents[black]! as Opened).text,
      draftText('Main (draft)', 'Black'),
    );
  });

  testWidgets('a draft made while the question is up that changes where the '
      'line goes stops it, and nothing is written', (tester) async {
    await openBeside(tester, const {});
    await listEveryFind(tester);
    await trainTheTrap(tester);
    expect(find.text('Add this line to “Main (draft)”?'), findsOneWidget);

    final made = inKid('Main (draft 2)');
    w.store.documents[made] = Opened(
      draftText('Main (draft 2)', 'White'),
      scriptedRevision(draftText('Main (draft 2)', 'White')),
    );
    w.chapterFiles.listing = kidWith([made]);
    await w.library.refresh();
    await tester.tap(find.text('Add and train'));
    await tester.pumpAndSettle();

    expect(w.requests.status, 'The drafts of Main changed. Try again.');
    expect(w.session.source, main);
    expect(w.lineTrainer.lesson, isNull);
    expect(
      w.store.documents.keys.where((k) => k.path.contains('(draft)')),
      isEmpty,
    );
    expect(
      (w.store.documents[made]! as Opened).text,
      draftText('Main (draft 2)', 'White'),
    );
  });

  testWidgets('with no chapter of that side open, it says so', (tester) async {
    await openWith(
      tester,
      '// Main\n// Color: Black\n\n[Event "L"]\n[Result "*"]\n\n1. e4 e5 *\n',
    );
    await trainTheTrap(tester);

    expect(
      w.requests.status,
      'Open a repertoire chapter for White to train it.',
    );
    expect(w.lineTrainer.lesson, isNull);
  });
}
