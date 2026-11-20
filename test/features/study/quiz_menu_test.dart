import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/study/quiz_menu.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

void main() {
  late StudyFixture study;
  final firstMove = NodePath.of(const [0]);

  setUp(() async => study = await openStudy(twoChapterStudy));
  tearDown(() => study.dispose());

  List<String> labels() => [
    for (final action in quizMenuItems(study.session, firstMove)) action.label,
  ];

  Future<void> press(String label) async {
    quizMenuItems(
      study.session,
      firstMove,
    ).singleWhere((action) => action.label == label).run!();
    await study.saver.flush();
  }

  test('the start of the game offers no quiz markers', () {
    expect(quizMenuItems(study.session, const NodePath.root()), isEmpty);
  });

  test('an unmarked move offers to start and to end a quiz there', () {
    expect(labels(), ['Start quiz from this move', 'End quiz after this move']);
  });

  test(
    'starting a quiz marks the move, and the entry then takes it off',
    () async {
      await press('Start quiz from this move');
      expect(study.onDisk, contains('1. e4 {[%tstart]} e5'));
      expect(labels(), [
        'Do not start a quiz here',
        'End quiz after this move',
      ]);

      await press('Do not start a quiz here');
      expect(study.onDisk, isNot(contains('[%tstart]')));
      expect(labels(), [
        'Start quiz from this move',
        'End quiz after this move',
      ]);
    },
  );

  test(
    'ending a quiz marks the move, and the entry then takes it off',
    () async {
      await press('End quiz after this move');
      expect(study.onDisk, contains('1. e4 {[%tend]} e5'));
      expect(labels(), ['Start quiz from this move', 'Do not end a quiz here']);

      await press('Do not end a quiz here');
      expect(study.onDisk, isNot(contains('[%tend]')));
      expect(labels(), [
        'Start quiz from this move',
        'End quiz after this move',
      ]);
    },
  );
}
