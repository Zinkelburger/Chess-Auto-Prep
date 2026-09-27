import 'dart:async';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/app/desktop_application.dart';
import 'package:chess_auto_prep/features/documents/controllers/document_close_coordinator.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_close_scope.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/memory_appearance_preferences.dart';
import '../support/memory_desktop_close_port.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    MemoryDesktopClosePort window,
    Widget child,
  ) async {
    await tester.pumpWidget(
      AppDependencies(
        settings: SharedPreferencesAppSettingsRepository(
          appearance: MemoryAppearancePreferences(),
        ),
        child: DesktopApplication(
          closePort: window,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('native failure leaves one dialog and allows an explicit retry', (
    tester,
  ) async {
    final window = MemoryDesktopClosePort()
      ..closeError = StateError('window unavailable');
    await mount(tester, window, const SizedBox.shrink());
    window.request!();
    window.request!();
    await tester.pumpAndSettle();
    expect(window.closes, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Keep app open'));
    await tester.pumpAndSettle();
    window.closeError = null;
    window.request!();
    await tester.pumpAndSettle();
    expect(window.closes, 1);
  });

  testWidgets('a late edit keeps the app open after all owners approve', (
    tester,
  ) async {
    final window = MemoryDesktopClosePort();
    final later = Completer<DocumentCloseApproval?>();
    var revision = 1;
    await mount(
      tester,
      window,
      DocumentCloseRegistration(
        revision: () => revision,
        prepare: () async => DocumentCloseApproval(revision),
        child: DocumentCloseRegistration(
          revision: () => 1,
          prepare: () => later.future,
          child: const Text('Documents'),
        ),
      ),
    );
    window.request!();
    await tester.pump();
    revision++;
    later.complete(const DocumentCloseApproval(1));
    await tester.pumpAndSettle();
    expect(window.closes, 0);
    expect(
      find.textContaining('A document changed while closing.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'unmounting a feature releases its registration, not the native policy',
    (tester) async {
      final window = MemoryDesktopClosePort();
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      var requests = 0;
      await mount(
        tester,
        window,
        ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, show, _) => show
              ? DocumentCloseRegistration(
                  revision: () => 1,
                  prepare: () async {
                    requests++;
                    return null;
                  },
                  child: const Text('Document'),
                )
              : const Text('Library'),
        ),
      );
      window.request!();
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(window.closes, 0);
      visible.value = false;
      await tester.pumpAndSettle();
      expect(window.attaches, 1);
      expect(window.detaches, 0);
      window.request!();
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(window.closes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(window.detaches, 1);
    },
  );
}
