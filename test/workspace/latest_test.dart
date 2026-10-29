import 'package:chess_auto_prep/workspace/latest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a newer request overtakes an older one', () {
    final asks = Latest();
    final first = asks.begin();
    expect(first.current, isTrue);
    final second = asks.begin();
    expect(first.overtaken, isTrue);
    expect(second.current, isTrue);
  });

  test('cancel overtakes every ticket and starts nothing', () {
    final asks = Latest();
    final ticket = asks.begin();
    asks.cancel();
    expect(ticket.overtaken, isTrue);
    expect(asks.begin().current, isTrue);
  });

  test('now joins the work under way without overtaking it', () {
    final checks = Latest();
    final first = checks.now;
    final second = checks.now;
    expect(first.current && second.current, isTrue);
    checks.cancel();
    expect(first.overtaken && second.overtaken, isTrue);
    final third = checks.now;
    expect(third.current, isTrue);
    checks.begin();
    expect(third.overtaken, isTrue);
  });

  test('close overtakes every ticket, even one taken after it', () {
    final asks = Latest();
    final before = asks.begin();
    asks.close();
    expect(before.overtaken, isTrue);
    expect(asks.begin().overtaken, isTrue);
    expect(asks.now.overtaken, isTrue);
  });
}
