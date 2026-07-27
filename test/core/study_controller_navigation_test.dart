import 'package:chess_auto_prep/core/move_navigation.dart';
import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';

/// [StudyController] used to hand-roll goBack/goForward/goToStart/goToEnd over
/// its `MoveTree` + `TreePath` cursor, duplicating [MoveNavigation]. These
/// tests pin the post-migration behaviour so the shared mixin can't regress it.

/// A controller whose single chapter holds 1.e4 e5 2.Nf3, plus the sideline
/// 1.d4 branching from the root.
StudyController _controllerWithLine() {
  final c = StudyController();
  final t = c.tree;
  final e4 = t.addMove(TreePath.empty, 'e4')!;
  final e5 = t.addMove(e4, 'e5')!;
  t.addMove(e5, 'Nf3');
  t.addMove(TreePath.empty, 'd4'); // sideline: second root
  return c;
}

void main() {
  test('StudyController adopts the shared MoveNavigation mixin', () {
    expect(StudyController(), isA<MoveNavigation>());
  });

  group('StudyController navigation', () {
    test('starts at the root', () {
      expect(_controllerWithLine().path, TreePath.empty);
    });

    test('goForward follows the mainline (children[0]) one ply at a time', () {
      final c = _controllerWithLine();
      c.goForward();
      expect(c.tree.nodeAt(c.path)!.san, 'e4');
      c.goForward();
      expect(c.tree.nodeAt(c.path)!.san, 'e5');
      c.goForward();
      expect(c.tree.nodeAt(c.path)!.san, 'Nf3');
    });

    test('goForward at a leaf is a no-op', () {
      final c = _controllerWithLine();
      c.goToEnd();
      final before = c.path;
      c.goForward();
      expect(c.path, before);
    });

    test('goBack steps toward the root', () {
      final c = _controllerWithLine();
      c.goToEnd();
      c.goBack();
      expect(c.tree.nodeAt(c.path)!.san, 'e5');
    });

    test('goBack at the root is a no-op', () {
      final c = _controllerWithLine();
      c.goBack();
      expect(c.path, TreePath.empty);
    });

    test('goToEnd walks to the end of the mainline', () {
      final c = _controllerWithLine();
      c.goToEnd();
      expect(c.tree.nodeAt(c.path)!.san, 'Nf3');
    });

    test('goToStart returns to the root from anywhere', () {
      final c = _controllerWithLine();
      c.goToEnd();
      c.goToStart();
      expect(c.path, TreePath.empty);
    });

    test('goForward prefers the first root, ignoring the sideline', () {
      final c = _controllerWithLine();
      c.goForward();
      expect(c.tree.nodeAt(c.path)!.san, 'e4', reason: 'not the d4 sideline');
    });

    test('jump rejects an invalid path and leaves the cursor put', () {
      final c = _controllerWithLine();
      c.goForward();
      final before = c.path;
      c.jump(const TreePath([99]));
      expect(c.path, before);
    });

    test('navigation notifies listeners', () {
      final c = _controllerWithLine();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.goForward();
      c.goBack();
      c.goToEnd();
      c.goToStart();
      expect(notifications, 4);
    });

    test('an empty tree survives every directional call', () {
      final c = StudyController();
      expect(c.tree.isEmpty, isTrue);
      expect(() {
        c.goForward();
        c.goBack();
        c.goToEnd();
        c.goToStart();
      }, returnsNormally);
      expect(c.path, TreePath.empty);
    });
  });
}
