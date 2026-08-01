/// The PGN viewer's Line tab: one verdict per designated book, and the prepared
/// line on the viewer's own board.
library;

import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/games/widgets/repertoire_line_panel.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sans = ['e4', 'c5', 'Nf3', 'd6', 'd4', 'Nf6'];

const _leftBook = DeviationReport(
  matchedPlies: 5,
  chapterPath: '/repertoire/Sicilian/open.pgn',
  chapterName: 'Open Sicilian',
  pathSans: ['e4', 'c5', 'Nf3', 'd6', 'd4'],
  playedSan: 'Nf6',
  byMe: true,
  expectedSans: ['cxd4'],
);

/// Answers with a fixed verdict per colour, so the panel is under test rather
/// than the walker.
class _StubDeviations extends GameDeviationService {
  _StubDeviations({required this.byColour});

  final Map<bool, Map<String, DeviationReport>> byColour;
  int calls = 0;

  @override
  Future<Map<String, DeviationReport>> analyzeGameByRepertoire({
    required List<String> gameSans,
    required bool meWhite,
    List<String>? folders,
  }) async {
    calls++;
    return byColour[meWhite] ?? const {};
  }
}

RepertoireLine _bookLine() => RepertoireLine(
  id: 'open-sicilian',
  name: 'Open Sicilian – Main',
  moves: const ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn:
      '[Event "Sicilian"]\n'
      '[Result "*"]\n'
      '\n'
      '1. e4 c5 2. Nf3 d6 3. d4 cxd4 '
      '{ Recapture with the knight. } 4. Nxd4 *',
);

/// A second line through the same prefix that answers the deviation with a
/// *different* move — every line the loader returns shares the matched prefix,
/// so the ply the game left at is the only place they differ.
RepertoireLine _sidelineFromSamePrefix() => RepertoireLine(
  id: 'open-sicilian-qxd4',
  name: 'Open Sicilian – Chekhover',
  moves: const ['e4', 'c5', 'Nf3', 'd6', 'd4', 'Qxd4'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn:
      '[Event "Sicilian"]\n'
      '[Result "*"]\n'
      '\n'
      '1. e4 c5 2. Nf3 d6 3. d4 Qxd4 *',
);

Future<void> _pump(
  WidgetTester tester, {
  required GameDeviationService service,
  ValueChanged<Position>? onShowPosition,
  void Function(DeviationReport)? onEditInBuilder,
  List<String> whiteBooks = const ['/repertoire/Sicilian'],
  List<RepertoireLine>? bookLines,
}) async {
  // A private settings instance, not the app-wide singleton: the singleton
  // caches its first load, so one test's designations would leak into the next.
  final settings = MyRepertoireSettings.forTest();
  await settings.setPaths(white: true, paths: whiteBooks);
  tester.view.physicalSize = const Size(900, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RepertoireLinePanel(
          gameLabel: 'me vs opp',
          sans: _sans,
          initialMeWhite: true,
          deviationService: service,
          settings: settings,
          onShowPosition: onShowPosition ?? (_) {},
          onEditInBuilder: onEditInBuilder,
          loadLines:
              ({
                required String chapterPath,
                required List<String> prefixSans,
              }) async => bookLines ?? [_bookLine()],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('names the book, the move, and what the book played', (
    tester,
  ) async {
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {'/repertoire/Sicilian': _leftBook},
        },
      ),
    );

    expect(find.textContaining('Sicilian · Open Sicilian'), findsOneWidget);
    expect(
      find.textContaining('You left book at move 3: 3... Nf6 instead of cxd4'),
      findsOneWidget,
    );
  });

  testWidgets('a single deviation opens its line without a second click', (
    tester,
  ) async {
    final positions = <Position>[];
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {'/repertoire/Sicilian': _leftBook},
        },
      ),
      onShowPosition: positions.add,
    );

    // The prepared line is on screen, and it pushed its landing position onto
    // the viewer's board — the point of the tab existing.
    expect(find.text('Open Sicilian – Main'), findsOneWidget);
    expect(find.text('Hide line'), findsOneWidget);
    expect(positions, isNotEmpty);
  });

  testWidgets('the comment on the prepared line is readable', (tester) async {
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {'/repertoire/Sicilian': _leftBook},
        },
      ),
    );

    expect(
      find.textContaining('Recapture with the knight.', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('it names the move you played against the move the book plays', (
    tester,
  ) async {
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {'/repertoire/Sicilian': _leftBook},
        },
      ),
    );

    expect(
      find.text('You played 3... Nf6 — this line plays 3... cxd4.'),
      findsOneWidget,
      reason: 'the fork is named, not left for the reader to spot',
    );
  });

  testWidgets('several book lines through the fork are all offered, by move', (
    tester,
  ) async {
    final positions = <Position>[];
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {'/repertoire/Sicilian': _leftBook},
        },
      ),
      onShowPosition: positions.add,
      bookLines: [_bookLine(), _sidelineFromSamePrefix()],
    );

    // The header counts them, and each row is labelled by the move that line
    // answers the deviation with — the only thing that differs between them.
    expect(find.text('2 book lines reach move 3'), findsOneWidget);
    // cxd4 is both a picker row and a move in the selected line's movetext.
    expect(find.text('cxd4'), findsWidgets);
    // Qxd4 is only the picker row: its line is not the one on screen yet.
    expect(find.text('Qxd4'), findsOneWidget);
    expect(find.text('Open Sicilian – Chekhover'), findsOneWidget);

    // Picking one swaps the movetext and the note under the header.
    await tester.tap(find.text('Qxd4'));
    await tester.pumpAndSettle();

    expect(
      find.text('You played 3... Nf6 — this line plays 3... Qxd4.'),
      findsOneWidget,
    );
  });

  testWidgets('an in-book game offers no line to show', (tester) async {
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {
            // No played move is what "stayed in book" means (see
            // DeviationReport.inBook).
            '/repertoire/Sicilian': const DeviationReport(
              matchedPlies: 6,
              chapterPath: '/repertoire/Sicilian/open.pgn',
              chapterName: 'Open Sicilian',
              pathSans: _sans,
            ),
          },
        },
      ),
    );

    expect(find.textContaining('In book the whole way'), findsOneWidget);
    expect(find.text('Show line'), findsNothing);
    expect(find.text('Hide line'), findsNothing);
  });

  testWidgets('switching colour re-asks, and says when nothing is designated', (
    tester,
  ) async {
    final service = _StubDeviations(
      byColour: {
        true: {'/repertoire/Sicilian': _leftBook},
      },
    );
    await _pump(tester, service: service);
    final callsBefore = service.calls;

    await tester.tap(find.text('Black'));
    await tester.pumpAndSettle();

    expect(service.calls, greaterThan(callsBefore));
    expect(
      find.textContaining('No Black book is designated'),
      findsOneWidget,
      reason: 'the panel says why it has nothing to report',
    );
  });

  testWidgets('editing the book is a separate, explicitly-named action', (
    tester,
  ) async {
    DeviationReport? edited;
    await _pump(
      tester,
      service: _StubDeviations(
        byColour: {
          true: {'/repertoire/Sicilian': _leftBook},
        },
      ),
      onEditInBuilder: (report) => edited = report,
    );

    await tester.tap(
      find.byTooltip('Edit this chapter in the Repertoire Builder'),
    );
    await tester.pump();

    expect(edited?.chapterName, 'Open Sicilian');
  });
}
