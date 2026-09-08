import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/updates/services/app_update_service.dart';
import 'package:chess_auto_prep/features/updates/widgets/app_updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_service_test.dart' show Installer, metadata;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'startup popup announces update, offers download, settings retain switches',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'updates.downloadAutomatically': false,
      });
      final dir = Directory.systemTemp.createTempSync('updates-widget-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = AppUpdateService(
        installer: Installer(),
        version: () async => '1.16.1',
        directory: () async => dir,
        client: MockClient(
          (_) async => http.Response(jsonEncode(metadata()), 200),
        ),
      );
      addTearDown(service.dispose);
      await tester.runAsync(() => service.initialize());
      await tester.pumpWidget(
        MaterialApp(
          home: AppUpdateHost(
            service: service,
            child: Scaffold(body: UpdateSettingsSection(service: service)),
          ),
        ),
      );
      await tester.runAsync(() => service.check());
      await tester.pumpAndSettle();
      expect(find.text('Chess Auto Prep 1.17.0 is available'), findsOneWidget);
      expect(find.text('Download update'), findsNWidgets(2));
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Check for updates automatically'), findsOneWidget);
      expect(find.text('Download updates automatically'), findsOneWidget);
      expect(find.text('Installed version: 1.16.1'), findsOneWidget);
    },
  );
}
