import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

Fen board(String name) => Fen('$name w - - 0 1');

/// A search in which, after 1.e4, the likely 1...f6 loses: a trap.
final trapTree = OurNode.over(
  fen: Fen.initial,
  evalForUs: const Eval(30),
  candidates: [
    CandidateMove(
      move: const MoveRef(uci: 'e2e4', san: 'e4'),
      child: OpponentNode.over(
        fen: board('after-e4'),
        evalForUs: const Eval(30),
        replies: [
          ReplyMove(
            move: const MoveRef(uci: 'e7e5', san: 'e5'),
            probability: 0.6,
            child: HorizonNode(fen: board('e5'), evalForUs: const Eval(0)),
          ),
          ReplyMove(
            move: const MoveRef(uci: 'f7f6', san: 'f6'),
            probability: 0.4,
            child: HorizonNode(fen: board('f6'), evalForUs: const Eval(250)),
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
  }) async {
    w.store.documents[main] = Opened(text, scriptedRevision(text));
    if (listed) w.chapterFiles.listing = kidWith(const []);
    await w.library.refresh();
    await w.session.open(main);
    await w.parts.workspace.finds.record(
      trapTree,
      rootFen: Fen.initial,
      prefix: const [],
      side: Side.white,
      elo: 1800,
    );
    await w.pumpShell(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
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

  testWidgets('a trap no chapter plays goes into the draft, asked first, '
      'and is trained there', (tester) async {
    await openWith(tester, chapterWith('1. d4 d5'));
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

  testWidgets('a trap goes into the draft already beside the chapter, as one '
      'edit', (tester) async {
    const draftText =
        '// Main (draft 2)\n// Draft\n// Color: White\n\n'
        '[Event "Old"]\n[Result "*"]\n\n1. c4 *\n';
    final draft = ChapterRef(
      repertoire: 'KID',
      name: 'Main (draft 2)',
      path: '/repertoires/KID/Main (draft 2).pgn',
      heading: const ChapterHeading(draft: true),
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
      trapTree,
      rootFen: Fen.initial,
      prefix: const [],
      side: Side.white,
      elo: 1800,
    );
    await w.pumpShell(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await trainTheTrap(tester);

    expect(find.textContaining('Add it to Main (draft 2)'), findsOneWidget);
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
    await trainTheTrap(tester);

    expect(find.textContaining('Add it to Main (draft 2)'), findsOneWidget);
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

  testWidgets('a draft beside the chapter for the other side is passed over', (
    tester,
  ) async {
    final black = inKid('Main (draft)');
    await openBeside(tester, {black: draftText('Main (draft)', 'Black')});
    await trainTheTrap(tester);

    expect(find.textContaining('Add it to Main (draft 2)'), findsOneWidget);
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
    await trainTheTrap(tester);
    expect(
      find.textContaining('Add it to Main (draft) first?'),
      findsOneWidget,
    );

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
