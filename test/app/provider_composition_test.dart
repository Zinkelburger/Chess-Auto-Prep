import 'dart:async';

import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/app/themed_application.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_catalog_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/features/settings/repositories/app_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../features/repertoires/repertoire_catalog_controller_test.dart'
    show Catalog;

class _Appearance implements AppearanceRepository {
  _Appearance(this.saved);
  final AppAppearance saved;
  int subscriptions = 0, cancellations = 0, loads = 0;
  late final _changes =
      StreamController<SettingsState<AppAppearance>>.broadcast(
        sync: true,
        onListen: () => subscriptions++,
        onCancel: () => cancellations++,
      );
  @override
  SettingsState<AppAppearance> state = const SettingsState();
  @override
  Stream<SettingsState<AppAppearance>> get changes => _changes.stream;
  @override
  Future<void> ensureLoaded() {
    expect(_changes.hasListener, true);
    loads++;
    state = SettingsState(phase: SettingsPhase.ready, committed: saved);
    _changes.add(state);
    return Future.value();
  }

  @override
  Future<void> reload() => ensureLoaded();
  @override
  Future<void> retry() => ensureLoaded();
  @override
  Future<void> setAppearance(AppAppearance value) => throw UnimplementedError();
  Future<void> close() => _changes.close();
}

class _Settings implements AppSettingsRepository {
  _Settings(this.appearance);
  @override
  final _Appearance appearance;
  @override
  RepertoireBooksRepository get repertoireBooks => throw UnimplementedError();
}

void main() {
  testWidgets(
    'appearance subscribes before synchronous loading and replaces borrowed overrides',
    (tester) async {
      final light = _Appearance(AppAppearance.light),
          dark = _Appearance(AppAppearance.dark);
      final repository = Catalog();
      Future<void> mount(_Appearance appearance) => tester.pumpWidget(
        AppDependencies(
          settings: _Settings(appearance),
          repertoireCatalog: repository,
          child: const ThemedApplication(
            home: Scaffold(body: Text('Theme probe')),
          ),
        ),
      );
      await mount(light);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('Theme probe'))).brightness,
        Brightness.light,
      );
      expect(light.loads, 1);
      await mount(dark);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('Theme probe'))).brightness,
        Brightness.dark,
      );
      expect(light.cancellations, 1);
      expect(dark.subscriptions, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(dark.cancellations, 1);
      // Injection borrows the repository; removing UI subscriptions does not close it.
      await light.close();
      await dark.close();
    },
  );

  testWidgets(
    'catalog override replacement disposes the old owner and ignores its late read',
    (tester) async {
      final appearance = _Appearance(AppAppearance.dark);
      final settings = _Settings(appearance);
      RepertoireCatalogController? current;
      Future<void> mount(Catalog repository) => tester.pumpWidget(
        AppDependencies(
          settings: settings,
          repertoireCatalog: repository,
          child: ThemedApplication(
            home: Builder(
              builder: (context) {
                current = context.watch<RepertoireCatalogController>();
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final oldRepository = Catalog();
      await mount(oldRepository);
      await tester.pumpAndSettle();
      final old = current!;
      final read = Completer<void>();
      oldRepository.read = () async {
        await read.future;
        return oldRepository.entries;
      };
      final pending = old.refresh();
      final replacement = Catalog();
      await mount(replacement);
      await tester.pumpAndSettle();
      expect(old.isDisposed, true);
      expect(current, isNot(same(old)));
      await current!.refresh();
      read.complete();
      await pending;
      await tester.pumpAndSettle();
      expect(replacement.reads, 1);
      expect(current!.snapshot().loadError, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await appearance.close();
    },
  );

  testWidgets(
    'catalog commit survives route loss and re-entry refreshes without replay',
    (tester) async {
      final repository = Catalog();
      final appearance = _Appearance(AppAppearance.dark);
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      late RepertoireCatalogController catalog;
      await tester.pumpWidget(
        AppDependencies(
          settings: _Settings(appearance),
          repertoireCatalog: repository,
          child: ThemedApplication(
            home: Builder(
              builder: (context) {
                catalog = context.read<RepertoireCatalogController>();
                return Scaffold(
                  body: ValueListenableBuilder<bool>(
                    valueListenable: visible,
                    builder: (_, show, _) => show
                        ? RepertoireListBody(onSelected: (_) {})
                        : const SizedBox(),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      repository.write = () => gate.future;
      final save = catalog.create(
        const CreateRepertoire(name: 'Offscreen', color: 'White'),
      );
      visible.value = false;
      await tester.pumpAndSettle();
      gate.complete();
      await save;
      final reads = repository.reads;
      visible.value = true;
      await tester.pumpAndSettle();
      expect(repository.reads, reads + 1);
      expect(repository.writes, 1);
      expect(find.text('Offscreen'), findsOneWidget);
      expect(catalog.isDisposed, false);
      await tester.pumpWidget(const SizedBox());
      expect(catalog.isDisposed, true);
      await appearance.close();
    },
  );
}
