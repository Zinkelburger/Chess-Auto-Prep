import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_import_dialog.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_catalog_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_entry.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_messages.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations_en.dart';
import 'package:chess_auto_prep/l10n/localized_time.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _ExpandedMessages extends AppLocalizationsEn {
  @override
  String get createRepertoire => 'Create this new personal repertoire';
  @override
  String get createNewRepertoire => 'Create a new personal chess repertoire';
  @override
  String get emptyRepertoire => 'Start an empty repertoire';
  @override
  String get openPgnFile => 'Open a chess repertoire PGN file…';
  @override
  String get cancel => 'Cancel this action';
  @override
  String get nameRequired => 'Enter a name for this chess repertoire';
  @override
  String get preparationFailed =>
      'The import could not be prepared. Your draft is still here. Keep it and retry when the library is available.';
}

class _ExpandedDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _ExpandedDelegate();
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';
  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(_ExpandedMessages());
  @override
  bool shouldReload(_ExpandedDelegate old) => false;
}

class _Catalog implements RepertoireCatalogRepository {
  @override
  bool get supportsRecovery => true;
  @override
  Future<List<RepertoireMetadata>> listRepertoires() async => [
    RepertoireMetadata(
      filePath: '/Library',
      name: 'My chess library',
      gameCount: 2,
      lastModified: DateTime(2020),
    ),
  ];
  @override
  Future<List<RepertoireMetadata>> listStudies() async => [];
  @override
  Future<List<RepertoireRecoveryEntry>> listRecovery() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(
  Widget home, {
  bool expanded = false,
  Locale? locale,
  double scale = 1,
}) => MaterialApp(
  theme: AppTheme.dark(),
  locale: locale,
  localizationsDelegates: [
    if (expanded) const _ExpandedDelegate(),
    ...AppLocalizations.localizationsDelegates,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: home,
);

void main() {
  testWidgets(
    'unsupported device locale falls back to English with plural messages',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              final messages = AppLocalizations.of(context);
              return Column(
                children: [
                  Text(messages.chapterCount(0)),
                  Text(messages.chapterCount(1)),
                  Text(messages.chapterCount(2)),
                  Text(messages.chapterCount(1200)),
                  Text(messages.repertoireExists('Échecs {1}')),
                ],
              );
            },
          ),
          locale: const Locale('fr', 'FR'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 chapters'), findsOneWidget);
      expect(find.text('1 chapter'), findsOneWidget);
      expect(find.text('2 chapters'), findsOneWidget);
      expect(find.text('1,200 chapters'), findsOneWidget);
      expect(
        find.text('A repertoire named "Échecs {1}" already exists.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'relative times share thresholds and older dates use locale formatting',
    () {
      final messages = AppLocalizationsEn();
      final now = DateTime(2026, 9, 16, 12);
      expect(
        formatLocalizedTimeAgo(
          messages,
          now.add(const Duration(minutes: 2)),
          now: now,
        ),
        'just now',
      );
      expect(
        formatLocalizedTimeAgo(
          messages,
          now.subtract(const Duration(minutes: 59)),
          now: now,
        ),
        '59m ago',
      );
      expect(
        formatLocalizedTimeAgo(
          messages,
          now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        '1h ago',
      );
      expect(
        formatLocalizedTimeAgo(
          messages,
          now.subtract(const Duration(days: 6)),
          now: now,
        ),
        '6d ago',
      );
      expect(
        formatLocalizedTimeAgo(messages, DateTime(2025, 9, 1), now: now),
        'Sep 1, 2025',
      );
    },
  );

  test('typed failures and name validation use presentation messages', () {
    final messages = _ExpandedMessages();
    expect(repertoireNameProblem(messages, ''), messages.nameRequired);
    expect(
      repertoireNameProblem(messages, '../escape'),
      messages.nameIllegalCharacters,
    );
    expect(repertoireNameProblem(messages, 'CON'), messages.nameSystemReserved);
    expect(repertoireNameProblem(messages, '合法名称'), isNull);
    expect(
      repertoireFailureMessage(
        messages,
        RepertoirePreparationFailed(StateError('private details')),
        fallback: 'fallback',
      ),
      messages.preparationFailed,
    );
    expect(
      repertoireFailureMessage(
        messages,
        const RepertoireRecoveryRequired('id', 'private path'),
        fallback: 'fallback',
      ),
      messages.recoveryRequired,
    );
    expect(
      repertoireFailureMessage(
        messages,
        StateError('private details'),
        fallback: 'fallback',
      ),
      'fallback',
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'expanded creation labels and retained failure fit at ${scale}x text',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        CreateRepertoire? request;
        await tester.pumpWidget(
          _app(
            RepertoireCreationScreen(
              create: (value) async {
                request = value;
                throw RepertoirePreparationFailed(StateError('disk offline'));
              },
            ),
            expanded: true,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        final messages = _ExpandedMessages();
        final create = find.widgetWithText(
          FilledButton,
          messages.createRepertoire,
        );
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(find.text(messages.nameRequired), findsOneWidget);
        expect(request, isNull);
        await tester.enterText(
          find.byKey(const ValueKey('repertoire-create-name')),
          'Échecs',
        );
        final empty = find.text(messages.emptyRepertoire);
        await tester.ensureVisible(empty);
        await tester.tap(empty);
        await tester.pumpAndSettle();
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(find.text(messages.preparationFailed), findsOneWidget);
        expect(request!.color, 'White');
        expect(request!.chapterName, 'Main');
        expect(request!.name, 'Échecs');
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('repertoire-create-name')),
              )
              .controller!
              .text,
          'Échecs',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'expanded paste failure stays readable and retains PGN at ${scale}x',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var attempted = false;
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showRepertoirePasteDialog(
                    context,
                    existingNames: [],
                    create: (_) async {
                      attempted = true;
                      throw RepertoirePreparationFailed(
                        StateError('disk offline'),
                      );
                    },
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
            expanded: true,
            scale: scale,
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('repertoire-import-pgn'));
        const source = '[Event "Preserve me"]\n\n1. e4 e5 *';
        await tester.enterText(field, source);
        await tester.pump();
        await tester.runAsync(
          () => tester.tap(find.widgetWithText(FilledButton, 'Import')),
        );
        final message = find.text(_ExpandedMessages().preparationFailed);
        for (var i = 0; i < 100 && message.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(attempted, isTrue);
        expect(message, findsOneWidget);
        await tester.ensureVisible(message);
        expect(tester.widget<TextField>(field).controller!.text, source);
        expect(tester.widget<Text>(message).maxLines, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'catalog search and recovery remain usable with expanded labels at ${scale}x',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => RepertoireCatalogController(_Catalog()),
            child: _app(
              Scaffold(body: RepertoireListBody(onSelected: (_) {})),
              expanded: true,
              scale: scale,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('My chess library'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'missing');
        await tester.pumpAndSettle();
        expect(find.text('Nothing matches "missing".'), findsOneWidget);
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(find.text('My chess library'), findsOneWidget);
        await tester.tap(find.byTooltip('Rename repertoire'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
        await tester.pumpAndSettle();
        expect(find.text(_ExpandedMessages().nameRequired), findsOneWidget);
        await tester.tap(find.text(_ExpandedMessages().cancel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recovery'));
        await tester.pumpAndSettle();
        expect(find.text('Recovery is empty'), findsOneWidget);
        await tester.tap(find.text('Back to library'));
        await tester.pumpAndSettle();
        expect(find.text('My chess library'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
