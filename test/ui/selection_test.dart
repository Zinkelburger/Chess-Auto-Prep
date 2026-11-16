// A move list's highlight: a move of the cursor flips the flag of the move
// it left and of the move it reached, and no other.
import 'package:chess_auto_prep/ui/selection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ValueNotifier<int> cursor;
  late Selection<int> selection;
  setUp(() {
    cursor = ValueNotifier(1);
    selection = Selection<int>()..follow(cursor);
  });
  tearDown(() {
    selection.dispose();
    cursor.dispose();
  });

  test('only the key the source is on is selected', () {
    expect(selection.of(1).value, isTrue);
    expect(selection.of(2).value, isFalse);
  });

  test('a move turns the old key off and the new one on, telling no other', () {
    final one = selection.of(1);
    final two = selection.of(2);
    final three = selection.of(3);
    var told = 0;
    three.addListener(() => told++);
    cursor.value = 2;
    expect(one.value, isFalse);
    expect(two.value, isTrue);
    expect(three.value, isFalse);
    expect(told, 0);
  });

  test('a key asked for after the move starts as the move left it', () {
    cursor.value = 3;
    expect(selection.of(3).value, isTrue);
    expect(selection.of(1).value, isFalse);
  });

  test('a new source forgets the flags handed out for the old one', () {
    final old = selection.of(1);
    final other = ValueNotifier(5);
    addTearDown(other.dispose);
    selection.follow(other);
    expect(selection.of(5).value, isTrue);
    expect(selection.of(1), isNot(same(old)));
    cursor.value = 2;
    expect(old.value, isTrue, reason: 'the old source is not heard');
  });

  test('after a reset the flags already handed out stop changing', () {
    final old = selection.of(1);
    selection.reset();
    cursor.value = 2;
    expect(old.value, isTrue);
    expect(selection.of(2).value, isTrue);
  });

  test('taken down, it hears its source no more', () {
    final two = selection.of(2);
    selection.dispose();
    cursor.value = 2;
    expect(two.value, isFalse);
  });
}
