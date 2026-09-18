import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import '../../support/runtime_settings.dart';
// Start refuses a numeric knob it cannot use and names it, instead of
// quietly building with a default in its place.

import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/widgets/generation/generation_config_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Finder _field(String labelPrefix) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.decoration?.labelText?.startsWith(labelPrefix) ?? false),
);

RuntimeSettings? _settings;
RuntimeSettings get settings => _settings ??= testRuntimeSettings();
void main() {
  setUp(() {
    _settings = null;
    addTearDown(() => _settings?.dispose());
  });
  late GlobalKey<GenerationConfigFormState> formKey;

  Future<void> pumpForm(
    WidgetTester tester, {
    TreeBuildConfig? initialConfig,
  }) async {
    formKey = GlobalKey<GenerationConfigFormState>();
    await pumpRuntimeWidget(
      tester,
      settings,
      MultiProvider(
        providers: [
          ChangeNotifierProvider<EvalDatabaseSettings>.value(
            value: settings.databases,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: GenerationConfigForm(
                isGenerating: false,
                initialConfig: initialConfig,
                playAsWhite: true,
                key: formKey,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const seed = TreeBuildConfig(
    startFen: kStandardStartFen,
    playAsWhite: true,
    buildMode: BuildMode.maiaDbExplore,
    enableChessDbApi: true,
  );
  final inheritedInvalid = [
    ('Ignore lines rarer than', seed.copyWith(minProbability: 1.01), true),
    ('Eval floor', seed.copyWith(minEvalCp: -10001), true),
    ('Eval ceiling', seed.copyWith(maxEvalCp: 10001), true),
    ('Opponent temperature', seed.copyWith(oppPolicyTemperature: 11), true),
    ('Your candidate moves per position', seed.copyWith(ourMultipv: 0), true),
    ('Leaf eval confidence', seed.copyWith(leafConfidence: 1.1), true),
    ('Alternative budget share', seed.copyWith(ourAltDiscount: -0.1), true),
    ('Skip alternatives behind by', seed.copyWith(fastAltGapCp: 501), true),
    ('Blend with Maia', seed.copyWith(maiaPriorGames: 100001), true),
    ('Always answer replies above', seed.copyWith(coverMinProb: 1.01), true),
    ('Verification depth', seed.copyWith(verifyDepth: 41), true),
    ('Setup tolerance', seed.copyWith(setupToleranceCp: 501), true),
    (
      'Natural-move tolerance',
      seed.copyWith(memorabilityToleranceCp: 501),
      true,
    ),
    (
      'Extra depth in master lines',
      seed.copyWith(masterDepthBonusPlies: 41),
      false,
    ),
    (
      'Master search-order weight',
      seed.copyWith(masterPriorityWeight: 3.1),
      false,
    ),
    (
      'Opponent replies off-book',
      seed.copyWith(offBookOppMaxChildren: 21),
      false,
    ),
    ('Reply window', seed.copyWith(replyWindowCp: 201), false),
  ];
  for (final (label, config, ignoredByPure) in inheritedInvalid) {
    testWidgets('inherited $label keeps its mode-specific validation', (
      tester,
    ) async {
      await pumpForm(tester, initialConfig: config);
      expect(
        formKey.currentState!.validateBeforeStart(),
        startsWith('$label: must be'),
      );
      await pumpForm(
        tester,
        initialConfig: config.copyWith(
          buildMode: BuildMode.stockfishExpectimax,
        ),
      );
      expect(
        formKey.currentState!.validateBeforeStart(),
        ignoredByPure ? isNull : startsWith('$label: must be'),
      );
    });
  }

  testWidgets('inherited nonfinite values retain validation and clamping', (
    tester,
  ) async {
    for (final value in [
      double.infinity,
      double.negativeInfinity,
      double.nan,
    ]) {
      await pumpForm(
        tester,
        initialConfig: seed.copyWith(minProbability: value),
      );
      final state = formKey.currentState!;
      expect(
        state.validateBeforeStart(),
        value.isNaN ? isNull : startsWith('Ignore lines rarer than: must be'),
      );
      expect(
        state
            .toConfig(startFen: kStandardStartFen, playAsWhite: true)
            .minProbability,
        value.isNegative ? 0 : 1,
      );
    }
  });

  testWidgets('Pure keeps its 64-ply validation limit', (tester) async {
    await pumpForm(
      tester,
      initialConfig: seed.copyWith(
        buildMode: BuildMode.stockfishExpectimax,
        maxPly: 65,
      ),
    );
    expect(
      formKey.currentState!.validateBeforeStart(),
      contains('pure supports at most 64 half-moves'),
    );
  });

  testWidgets('editable errors precede inherited errors and both block Start', (
    tester,
  ) async {
    await pumpForm(tester, initialConfig: seed.copyWith(minProbability: 1.01));
    await tester.enterText(_field('Max line length'), 'invalid');
    await tester.pump();
    expect(
      formKey.currentState!.validateBeforeStart(),
      startsWith('Max line length:'),
    );
    await tester.enterText(_field('Max line length'), '12');
    await tester.pump();
    expect(
      formKey.currentState!.validateBeforeStart(),
      startsWith('Ignore lines rarer than:'),
    );
  });

  testWidgets('a fresh form validates clean', (tester) async {
    await pumpForm(tester);
    expect(formKey.currentState!.validateBeforeStart(), isNull);
  });

  testWidgets('a decimal in a whole-number field is refused by name', (
    tester,
  ) async {
    await pumpForm(tester);

    await tester.enterText(_field('Max line length'), '20.5');
    await tester.pump();

    final error = formKey.currentState!.validateBeforeStart();
    expect(error, contains('Max line length'));
    expect(error, contains('whole number'));
    // The field says so too, under itself.
    expect(find.textContaining('Whole number'), findsOneWidget);
  });

  testWidgets('an out-of-range value is refused with the range', (
    tester,
  ) async {
    await pumpForm(tester);

    await tester.enterText(_field('Opponent rating'), '9000');
    await tester.pump();

    expect(
      formKey.currentState!.validateBeforeStart(),
      contains('Opponent rating: must be 500–3500'),
    );
  });

  testWidgets('an empty field is refused', (tester) async {
    await pumpForm(tester);

    await tester.enterText(_field('Max line length'), '');
    await tester.pump();

    expect(
      formKey.currentState!.validateBeforeStart(),
      contains('Max line length: enter a number'),
    );
  });
}
