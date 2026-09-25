import 'dart:io';

import 'package:chess_auto_prep/debug/desktop_self_test.dart';
import 'package:chess_auto_prep/v2/app/app.dart';
import 'package:chess_auto_prep/v2/app/shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('v2 native documents, engines and login sockets work', (
    tester,
  ) async {
    final report = await checkDesktop();
    expect(report['ok'], true, reason: '$report');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('v2 boots into its real desktop shell with a fresh profile', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('v2-boot-');
    try {
      await tester.pumpWidget(
        ChessAutoPrepV2(
          documents: Directory(p.join(root.path, 'Documents')),
          support: Directory(p.join(root.path, 'Support')),
          logFolder: Directory(p.join(root.path, 'logs')),
          closeLog: () async {},
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(Shell), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
