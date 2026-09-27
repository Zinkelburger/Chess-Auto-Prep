import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/design_system/theme/workspace_theme.dart';
import 'package:chess_auto_prep/features/documents/controllers/solitaire_controller.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_opening_tree_panel.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_slice_chips.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_tree_toolbar.dart';
import 'package:chess_auto_prep/widgets/pgn/solitaire_status_widgets.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {ThemeData? theme, double scale = 1}) => MaterialApp(
  theme: theme ?? AppTheme.dark(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 550, child: child),
    ),
  ),
);

SolitaireSetupStrip setup({
  int count = 4,
  ValueChanged<bool>? side,
  VoidCallback? begin,
}) => SolitaireSetupStrip(
  userIsWhite: true,
  fromCurrentMove: false,
  includeVariations: true,
  canStartHere: true,
  hasSidelines: true,
  startHereLabel: 'after 13.Nf3',
  userMovesToGuess: count,
  revealDelaySeconds: 60,
  onUserSideChanged: side ?? (_) {},
  onFromCurrentMoveChanged: (_) {},
  onIncludeVariationsChanged: (_) {},
  onRevealDelayChanged: (_) {},
  onCancel: () {},
  onBegin: begin ?? () {},
);

PgnOpeningTreePanel panel({
  bool building = false,
  ValueChanged<bool>? variation,
}) => PgnOpeningTreePanel(
  tree: null,
  gameCount: 10,
  includeVariations: false,
  building: building,
  processed: 3,
  total: 10,
  currentMoveSequence: const [],
  wdlPerspective: WdlPerspective.playerIsWhite,
  matchingGames: const [],
  currentMatchingIndex: -1,
  onIncludeVariationsChanged: variation ?? (_) {},
  onMoveSelected: (_) {},
  onGoBack: () {},
  onGoForward: () {},
  onGameSelected: (_) {},
);

PgnTreeToolbar toolbar({
  SliceConfig? config,
  Future<void> Function(SliceConfig)? apply,
  Future<void> Function(HeaderFilterConfig)? preset,
  bool loading = false,
}) => PgnTreeToolbar(
  config: config ?? const SliceConfig(),
  player: 'Carlsen, Magnus',
  loading: loading,
  hasActiveFilters: config != null,
  database: false,
  onSourceChanged: (_) {},
  onFilter: () {},
  onApplyPreset: preset ?? (_) async {},
  onApplyConfig: apply ?? (_) async {},
);

void main() {
  testWidgets(
    'tree side filter delegates apply and removal without dropping other filters',
    (tester) async {
      HeaderFilterConfig? selected;
      await tester.pumpWidget(
        host(toolbar(preset: (value) async => selected = value)),
      );
      await tester.ensureVisible(find.text('White'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('White'));
      expect(selected!.field, 'White');
      expect(selected!.value, 'Carlsen, Magnus');
      SliceConfig? cleared;
      final config = SliceConfig(
        positionInput: 'e4',
        headerFilters: [
          selected!,
          const HeaderFilterConfig(
            field: 'Event',
            mode: MatchMode.exact,
            value: 'Candidates',
          ),
        ],
      );
      await tester.pumpWidget(
        host(toolbar(config: config, apply: (value) async => cleared = value)),
      );
      await tester.ensureVisible(find.text('White'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('White'));
      expect(cleared!.positionInput, 'e4');
      expect(cleared!.headerFilters.single.value, 'Candidates');
      selected = null;
      await tester.pumpWidget(
        host(toolbar(loading: true, preset: (value) async => selected = value)),
      );
      await tester.ensureVisible(find.text('Black'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Black'));
      expect(selected, isNull);
    },
  );

  testWidgets(
    'filter chips preserve display order for removal and edit actions',
    (tester) async {
      final removed = <int>[];
      var edits = 0;
      await tester.pumpWidget(
        host(
          PgnSliceChips(
            config: const SliceConfig(
              positionInput: 'e4',
              sequencePattern: 'Nf3',
              headerFilters: [
                HeaderFilterConfig(
                  field: 'Event',
                  mode: MatchMode.exact,
                  value: 'Candidates',
                ),
              ],
            ),
            onRemoveChip: removed.add,
            onOpenSliceDialog: () => edits++,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Remove Position: e4'));
      expect(removed, [0]);
      await tester.tap(find.byTooltip('Edit Position: e4'));
      expect(edits, 1);
    },
  );

  testWidgets('setup choices and empty drill start use supplied actions', (
    tester,
  ) async {
    bool? side;
    var starts = 0;
    await tester.pumpWidget(
      host(setup(side: (value) => side = value, begin: () => starts++)),
    );
    await tester.ensureVisible(find.text('Black'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Black'));
    expect(side, isFalse);
    await tester.tap(find.text('Start').last);
    expect(starts, 1);
    await tester.pumpWidget(host(setup(count: 0, begin: () => starts++)));
    await tester.tap(find.text('Start').last);
    expect(starts, 1);
  });

  testWidgets('solitaire help uses existing rule owner and supplied actions', (
    tester,
  ) async {
    final controller = SolitaireController()..revealDelaySec = 0;
    addTearDown(controller.dispose);
    controller.start(
      script: const SolitaireScript(
        steps: [
          SolitaireStep(san: 'e4', before: Chess.initial, mainlinePly: 0),
        ],
        startMainlinePly: 0,
        includesVariations: false,
      ),
      userPlaysWhite: true,
    );
    var hints = 0;
    var reveals = 0;
    await tester.pumpWidget(
      host(
        SolitaireStatusBar(
          controller: controller,
          onHint: () => hints++,
          onReveal: () => reveals++,
          onExit: () {},
        ),
      ),
    );
    await tester.tap(find.text('Hint'));
    await tester.tap(find.text('Reveal'));
    expect([hints, reveals], [1, 1]);
  });

  testWidgets(
    'completion actions use supplied commands without a Viewer facade',
    (tester) async {
      final controller = SolitaireController();
      addTearDown(controller.dispose);
      final calls = <String>[];
      await tester.pumpWidget(
        host(
          SolitaireCompleteBanner(
            controller: controller,
            onNextGame: () => calls.add('next'),
            onCopyPgn: () => calls.add('copy'),
            onAddToStudy: () => calls.add('study'),
            onAnalyse: () => calls.add('analyse'),
            onExit: () => calls.add('exit'),
          ),
        ),
      );
      await tester.tap(find.text('Copy PGN'));
      await tester.tap(find.text('Add to study…'));
      await tester.tap(find.text('Next game (↓)'));
      await tester.tap(find.text('Exit solitaire'));
      expect(calls, ['copy', 'study', 'next', 'exit']);
    },
  );

  testWidgets(
    'tree variation control delegates without owning a mutable tree',
    (tester) async {
      bool? include;
      await tester.pumpWidget(
        host(
          SizedBox(
            height: 450,
            child: panel(variation: (value) => include = value),
          ),
        ),
      );
      await tester.tap(find.text('Include variations'));
      expect(include, isTrue);
      expect(
        find.text('No tree available.\nLoad games to build.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tree search captures selected game identity through list changes',
    (tester) async {
      final first = PgnGameEntry(
        headers: {'White': 'First'},
        pgnText: '1. e4 *',
      );
      final second = PgnGameEntry(
        headers: {'White': 'Second'},
        pgnText: '1. d4 *',
      );
      final games = [first, second];
      PgnGameEntry? selected;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => openTreePositionGameSearch(
                context: context,
                games: games,
                currentIndex: 0,
                onSelected: (game) => selected = game,
              ),
              child: const Text('Search'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      games.removeAt(0);
      await tester.tap(find.textContaining('First').first);
      await tester.pumpAndSettle();
      expect(selected, same(first));
    },
  );

  testWidgets(
    'filter chips remain usable in the fixed app bar at 200 percent',
    (tester) async {
      var removed = false;
      await tester.pumpWidget(
        host(
          SizedBox(
            height: kToolbarHeight,
            child: PgnSliceChips(
              config: const SliceConfig(
                headerFilters: [
                  HeaderFilterConfig(
                    field: 'Event',
                    mode: MatchMode.exact,
                    value: 'Candidates',
                  ),
                ],
              ),
              onRemoveChip: (_) => removed = true,
              onOpenSliceDialog: () {},
            ),
          ),
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Edit Event is Candidates'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove Event is Candidates'));
      expect(removed, isTrue);
    },
  );

  for (final theme in [AppTheme.dark(), AppTheme.light()]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'leaf controls follow ${theme.brightness} theme at $scale scale',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(900, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(host(setup(), theme: theme, scale: scale));
          expect(tester.takeException(), isNull);
          final chip = tester.widget<FilterChip>(find.byType(FilterChip));
          final foreground = chip.labelStyle!.color!;
          final background = chip.selectedColor!;
          final a = foreground.computeLuminance();
          final b = background.computeLuminance();
          expect(
            (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05),
            greaterThanOrEqualTo(4.5),
          );
          final solitaire = SolitaireController();
          addTearDown(solitaire.dispose);
          await tester.pumpWidget(
            host(
              SolitaireStatusBar(
                controller: solitaire,
                onHint: () {},
                onReveal: () {},
                onExit: () {},
              ),
              theme: theme,
              scale: scale,
            ),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            host(
              SolitaireCompleteBanner(
                controller: solitaire,
                onNextGame: () {},
                onCopyPgn: () {},
                onAddToStudy: () {},
                onAnalyse: () {},
                onExit: () {},
              ),
              theme: theme,
              scale: scale,
            ),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(host(toolbar(), theme: theme, scale: scale));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            host(
              PgnSliceChips(
                config: const SliceConfig(positionInput: 'e4'),
                onRemoveChip: (_) {},
                onOpenSliceDialog: () {},
              ),
              theme: theme,
              scale: scale,
            ),
          );
          expect(tester.takeException(), isNull);
          final chipMaterial = tester.widget<Material>(
            find
                .descendant(
                  of: find.byKey(const ValueKey(('applied-filter', 0))),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(chipMaterial.color, theme.extension<WorkspaceTheme>()!.inset);
          final label = tester.widget<Text>(find.text('e4'));
          expect(label.style!.color, theme.colorScheme.onSurface);
          await tester.pumpWidget(
            host(
              SizedBox(height: 450, child: panel(building: true)),
              theme: theme,
              scale: scale,
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          final count = tester.widget<Text>(find.text('10 games'));
          expect(count.style!.color, theme.colorScheme.onSurface);
        },
      );
    }
  }
}
