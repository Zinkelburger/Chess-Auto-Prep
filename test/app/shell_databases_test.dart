import 'package:chess_auto_prep/app/mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  testWidgets('database mode keeps the workspace and its navigation history', (
    tester,
  ) async {
    final app = WindowFixture();
    addTearDown(app.dispose);
    await app.pumpShell(tester);
    await app.requests.open(kidMain);
    final chapter = app.parts.session.chapter;
    app.requests.switchTo(Mode.databases);
    await tester.pumpAndSettle();
    expect(find.text('Import PGN…'), findsOneWidget);
    expect(
      find.text('Import a PGN to add your own games here.'),
      findsOneWidget,
    );
    expect(app.parts.session.chapter, same(chapter));
    await app.requests.back();
    await tester.pumpAndSettle();
    expect(app.requests.mode, Mode.repertoires);
    expect(app.parts.session.chapter, same(chapter));
    expect(tester.takeException(), isNull);
  });
}
