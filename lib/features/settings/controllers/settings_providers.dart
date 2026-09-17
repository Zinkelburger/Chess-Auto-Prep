import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/repertoire_books.dart';
import '../models/app_appearance.dart';
import '../models/settings_state.dart';
import '../repositories/app_settings_repository.dart';

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>(
  (ref) => throw StateError('App settings repository was not injected'),
  retry: (count, error) => null,
);

/// Only this section changes its listeners. Subscribing never retries a failed
/// save; an explicit user action is required to replay a failed edit.
final repertoireBooksSettingsProvider =
    StreamProvider<SettingsState<RepertoireBooks>>((ref) {
      final books = ref.watch(appSettingsRepositoryProvider).repertoireBooks;
      return Stream.multi((controller) {
        final subscription = books.changes.listen(controller.addSync);
        controller.addSync(books.state);
        controller.onCancel = subscription.cancel;
        unawaited(
          books.ensureLoaded().catchError((Object _) {
            // The repository publishes a typed failed state with the last value.
          }),
        );
      });
    }, retry: (count, error) => null);

final appearanceSettingsProvider = StreamProvider<SettingsState<AppAppearance>>(
  (ref) {
    final appearance = ref.watch(appSettingsRepositoryProvider).appearance;
    return Stream.multi((controller) {
      final subscription = appearance.changes.listen(controller.addSync);
      controller.addSync(appearance.state);
      controller.onCancel = subscription.cancel;
      unawaited(appearance.ensureLoaded().catchError((Object _) {}));
    });
  },
  retry: (count, error) => null,
);
