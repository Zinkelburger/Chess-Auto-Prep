import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/training/models/chapter_layout.dart'
    show ChapterSummary;
import 'package:chess_auto_prep/design_system/components/empty_state_placeholder.dart';
import 'package:chess_auto_prep/design_system/components/list_search_field.dart';
import 'package:chess_auto_prep/design_system/theme/app_spacing.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_catalog_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_entry.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/widgets/pgn_import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:widgetbook/widgetbook.dart';

List<WidgetbookNode> repertoireCases() => [
  WidgetbookFolder(
    name: 'Repertoires',
    children: [
      WidgetbookComponent(
        name: 'Library',
        useCases: [
          for (final scenario in CatalogScenario.values)
            WidgetbookUseCase(
              name: scenario.name,
              builder: (_) => CatalogCaseHost(
                child: CatalogFixture(
                  key: ValueKey(scenario),
                  scenario: scenario,
                ),
              ),
            ),
        ],
      ),
      WidgetbookComponent(
        name: 'Creation',
        useCases: [
          for (final outcome in CreationOutcome.values)
            WidgetbookUseCase(
              name: outcome.name,
              builder: (_) =>
                  CatalogCaseHost(child: CreationFixture(outcome: outcome)),
            ),
        ],
      ),
      WidgetbookComponent(
        name: 'Search',
        useCases: [
          WidgetbookUseCase(
            name: 'interactive',
            builder: (_) => const CatalogCaseHost(child: SearchFixture()),
          ),
        ],
      ),
      WidgetbookComponent(
        name: 'Empty state',
        useCases: [
          WidgetbookUseCase(
            name: 'with action',
            builder: (_) => CatalogCaseHost(
              child: Builder(
                builder: (context) {
                  final messages = AppLocalizations.of(context);
                  return Scaffold(
                    body: EmptyStatePlaceholder(
                      icon: Icons.library_books,
                      title: messages.catalogEmpty,
                      subtitle: messages.catalogEmptyHelp,
                      actionLabel: messages.createNewRepertoire,
                      onAction: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CreationFixture(
                            outcome: CreationOutcome.success,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ],
  ),
];

/// A Navigator below Widgetbook's active theme/scale, so pushed forms and
/// dialogs inherit the same fixture configuration as the entry screen.
class CatalogCaseHost extends StatelessWidget {
  const CatalogCaseHost({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Theme.of(context),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => _CatalogTextScale(
        scale: scale,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scale),
          child: child!,
        ),
      ),
      home: child,
    );
  }
}

/// Material dialogs capture InheritedTheme when using the root navigator.
/// Capture the fixture's text scale too, rather than silently previewing dialogs
/// at Widgetbook chrome's 100% scale while the rest of the case is enlarged.
class _CatalogTextScale extends InheritedTheme {
  const _CatalogTextScale({required this.scale, required super.child});
  final TextScaler scale;
  @override
  bool updateShouldNotify(_CatalogTextScale oldWidget) =>
      scale != oldWidget.scale;
  @override
  Widget wrap(BuildContext context, Widget child) => _CatalogTextScale(
    scale: scale,
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: child,
    ),
  );
}

enum CatalogScenario { empty, populated, recovery, unavailable }

enum CreationOutcome { success, slow, failure }

const _source = PickedPgnImport(
  suggestedName: 'Imported fixture',
  suggestedColor: 'Black',
  result: PgnImportResult(
    pgnContent: '[Event "Fixture"]\n\n1. e4 c6 *',
    gameCount: 1,
    fileName: 'Fixture.pgn',
  ),
);

class CatalogFixture extends StatefulWidget {
  const CatalogFixture({super.key, required this.scenario});
  final CatalogScenario scenario;
  @override
  State<CatalogFixture> createState() => _CatalogFixtureState();
}

class _CatalogFixtureState extends State<CatalogFixture> {
  late final repository = FixtureRepertoireRepository(widget.scenario);
  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
    create: (_) => RepertoireCatalogController(repository),
    child: Scaffold(
      body: RepertoireListBody(
        onSelected: (_) {},
        onRepertoireSelected: (_) {},
        pickPgn: () async => _source,
        browseChapters: (context, repertoire) async {
          await showDialog<void>(
            context: context,
            useRootNavigator: false,
            builder: (_) => AlertDialog(
              title: Text(repertoire.name),
              content: Text(
                AppLocalizations.of(context).chapterCount(repertoire.gameCount),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(AppLocalizations.of(context).cancel),
                ),
              ],
            ),
          );
          return null;
        },
      ),
    ),
  );
}

class CreationFixture extends StatelessWidget {
  const CreationFixture({super.key, required this.outcome});
  final CreationOutcome outcome;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(
        onPressed: () => Navigator.of(context).push<RepertoireCreationResult>(
          MaterialPageRoute(
            builder: (_) => RepertoireCreationScreen(
              pickPgn: () async => _source,
              create: (request) async {
                if (outcome == CreationOutcome.slow) {
                  await Future<void>.delayed(const Duration(seconds: 3));
                }
                if (outcome == CreationOutcome.failure) {
                  throw RepertoirePreparationFailed(
                    StateError('Scripted failure; no files written'),
                  );
                }
                return RepertoireCreationResult(
                  directoryPath: '/fixture/${request.name}',
                  chapterPath: '/fixture/${request.name}/Main.pgn',
                  gameCount: 0,
                );
              },
            ),
          ),
        ),
        child: Text(AppLocalizations.of(context).createRepertoire),
      ),
    ),
  );
}

class SearchFixture extends StatefulWidget {
  const SearchFixture({super.key});
  @override
  State<SearchFixture> createState() => _SearchFixtureState();
}

class _SearchFixtureState extends State<SearchFixture> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final messages = AppLocalizations.of(context);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          children: [
            ListSearchField(
              hintText: messages.searchRepertoires,
              clearLabel: messages.clearSearch,
              onChanged: (value) {
                if (mounted) setState(() => query = value);
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(messages.nothingMatches(query)),
          ],
        ),
      ),
    );
  }
}

/// Stateful fake of the public repository contract, shared by interactive cases.
/// Every path is an inert label. No fallback to production storage is possible.
class FixtureRepertoireRepository implements RepertoireCatalogRepository {
  FixtureRepertoireRepository(this.scenario) {
    if (scenario == CatalogScenario.populated) {
      entries.addAll([
        _entry('Sicilian — main lines and sidelines', 12),
        _entry(
          'A long repertoire title for practicing against uncommon opening moves and transpositions',
          1200,
        ),
      ]);
    }
    if (scenario == CatalogScenario.recovery) {
      recovery.add(
        RepertoireRecoveryEntry(
          id: 'recovery-fixture',
          name: 'French defence',
          originalPath: '/fixture/French defence',
          deletedAt: DateTime(2026, 9, 1),
          available: true,
        ),
      );
    }
  }
  final CatalogScenario scenario;
  final entries = <RepertoireMetadata>[];
  final recovery = <RepertoireRecoveryEntry>[];
  int serial = 0;
  @override
  bool get supportsRecovery => true;
  RepertoireMetadata _entry(String name, int count) => RepertoireMetadata(
    filePath: '/fixture/$name',
    name: name,
    gameCount: count,
    lastModified: DateTime(2026, 9, 1),
  );
  @override
  Future<List<RepertoireMetadata>> listRepertoires() async {
    if (scenario == CatalogScenario.unavailable) {
      throw StateError('Scripted unavailable library');
    }
    return [...entries];
  }

  @override
  Future<List<RepertoireMetadata>> listChapters(String folderPath) async => [];
  @override
  Future<PgnOpenResult> prepareChapterDeletion(String path) async =>
      const PgnMissing();
  @override
  Future<PgnQuarantineResult> deleteChapter(PgnSnapshot baseline) async =>
      PgnQuarantineFailed(UnsupportedError('Fixture deletion unavailable'));
  @override
  Future<List<ChapterSummary>> chapterSections(String path) async => [];
  @override
  Future<PgnWriteResult> createChapter({
    required String folderPath,
    required String name,
    bool? isWhite,
  }) async => PgnWriteFailed(
    UnsupportedError('This catalog fixture has no chapter editor.'),
  );

  @override
  Future<List<RepertoireMetadata>> listStudies() async => [];
  @override
  Future<List<RepertoireRecoveryEntry>> listRecovery() async => [...recovery];
  @override
  Future<RepertoireCreationResult> create(CreateRepertoire request) async {
    if (entries.any(
      (entry) => entry.name.toLowerCase() == request.name.toLowerCase(),
    )) {
      throw RepertoireExistsException(request.name);
    }
    entries.add(_entry(request.name, 1));
    return RepertoireCreationResult(
      directoryPath: '/fixture/${request.name}',
      chapterPath: '/fixture/${request.name}/Main.pgn',
      gameCount: 0,
    );
  }

  @override
  Future<void> rename(RepertoireMetadata repertoire, String name) async {
    entries[entries.indexOf(repertoire)] = _entry(name, repertoire.gameCount);
  }

  @override
  Future<void> moveToRecovery(RepertoireMetadata repertoire) async {
    entries.remove(repertoire);
    recovery.add(
      RepertoireRecoveryEntry(
        id: 'deleted-${serial++}',
        name: repertoire.name,
        originalPath: repertoire.filePath,
        deletedAt: DateTime.now(),
        available: true,
      ),
    );
  }

  @override
  Future<void> restore(String id, {String? name}) async {
    final item = recovery.singleWhere((item) => item.id == id);
    entries.add(_entry(name ?? item.name, 1));
    recovery.remove(item);
  }
}
