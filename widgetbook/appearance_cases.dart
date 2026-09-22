import 'dart:async';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/features/settings/widgets/appearance_settings.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/features/settings/repositories/app_settings_repository.dart';

List<WidgetbookNode> appearanceCases() => [
  WidgetbookFolder(
    name: 'Settings',
    children: [
      WidgetbookComponent(
        name: 'Appearance',
        useCases: [
          for (final failure in [false, true])
            WidgetbookUseCase(
              name: failure ? 'write failure' : 'saved choice',
              builder: (_) => _AppearanceFixture(failure: failure),
            ),
        ],
      ),
    ],
  ),
];

class _FixtureSettings implements AppSettingsRepository {
  _FixtureSettings(bool failure) : appearance = _MemoryAppearance(failure);
  @override
  final _MemoryAppearance appearance;
  @override
  RepertoireBooksRepository get repertoireBooks =>
      throw UnsupportedError('Books are outside this appearance fixture');
}

class _MemoryAppearance implements AppearanceRepository {
  _MemoryAppearance(this.failure);
  final bool failure;
  final _changes = StreamController<SettingsState<AppAppearance>>.broadcast(
    sync: true,
  );
  @override
  SettingsState<AppAppearance> state = const SettingsState(
    phase: SettingsPhase.ready,
    committed: AppAppearance.dark,
  );
  @override
  Stream<SettingsState<AppAppearance>> get changes => _changes.stream;
  void _emit(SettingsState<AppAppearance> next) {
    state = next;
    _changes.add(next);
  }

  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> reload() async => _emit(
    SettingsState(phase: SettingsPhase.ready, committed: state.committed),
  );
  @override
  Future<void> retry() => setAppearance(state.draft ?? state.committed!);
  @override
  Future<void> setAppearance(AppAppearance value) async {
    if (failure) {
      final error = StateError('Fixture write failed');
      _emit(
        SettingsState(
          phase: SettingsPhase.failed,
          committed: state.committed,
          draft: value,
          error: error,
        ),
      );
      throw error;
    }
    _emit(SettingsState(phase: SettingsPhase.ready, committed: value));
  }

  void dispose() => unawaited(_changes.close());
}

class _AppearanceFixture extends StatefulWidget {
  const _AppearanceFixture({required this.failure});
  final bool failure;
  @override
  State<_AppearanceFixture> createState() => _AppearanceFixtureState();
}

class _AppearanceFixtureState extends State<_AppearanceFixture> {
  late final repository = _FixtureSettings(widget.failure);
  @override
  void dispose() {
    repository.appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<AppearanceRepository>.value(value: repository.appearance),
      StreamProvider<SettingsState<AppAppearance>>.value(
        value: repository.appearance.changes,
        initialData: repository.appearance.state,
      ),
    ],
    child: Localizations(
      locale: const Locale('en'),
      delegates: AppLocalizations.localizationsDelegates,
      child: const Scaffold(body: AppearanceSettings()),
    ),
  );
}
