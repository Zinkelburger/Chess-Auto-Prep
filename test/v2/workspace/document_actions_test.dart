import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/workspace/document_actions.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';
import '../support/viewer_fixture.dart';

void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late ValueNotifier<bool> editing;

  setUp(() async {
    fixture = await openSession(blackChapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => const StartFailed('no engine in this test'),
    );
    editing = ValueNotifier(false);
  });

  tearDown(() {
    editing.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  List<String> labels(SessionFixture of) => [
    for (final action in documentActions(
      session: of.session,
      analysis: analysis,
      editing: editing,
      onSaveCopy: () {},
    ))
      action.run == null ? '${action.label} (off)' : action.label,
  ];

  test('the menu keeps its shape; what cannot be done now is off', () {
    expect(labels(fixture), [
      'Edit',
      'Undo (off)',
      'Save a copy…',
      'Flip board',
      'Engine on',
      'Copy game PGN',
      'Copy FEN',
    ]);
    editing.value = true;
    expect(labels(fixture).first, 'Done editing');
  });

  test('the text copied for a merged chapter is the whole file', () {
    expect(gameText(fixture.session), blackChapter);
  });

  test('the text copied for a viewed game is that game alone', () async {
    final viewed = await viewerOver(threeGameFile);
    addTearDown(viewed.dispose);
    await viewed.open(game: 1);
    expect(gameText(viewed.session), startsWith('[Event "Tata Steel"]'));
    expect(gameText(viewed.session), contains('Ding, Liren'));
    expect(gameText(viewed.session), isNot(contains('Carlsen')));
  });
}
