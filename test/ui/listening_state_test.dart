// A state that follows the listenable its widget names: rebuilt with
// another, it leaves the old one and joins the new; stopped, it hears
// nothing more, rebuilt or not.
import 'package:chess_auto_prep/ui/listening_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> heard;
  late ValueNotifier<int> first;
  late ValueNotifier<int> second;
  setUp(() {
    heard = [];
    first = ValueNotifier(0);
    second = ValueNotifier(0);
  });
  tearDown(() {
    first.dispose();
    second.dispose();
  });

  Future<void> show(WidgetTester tester, Listenable? follows) =>
      tester.pumpWidget(_Follower(follows, heard));

  testWidgets('runs on each notification of what it follows', (tester) async {
    await show(tester, first);
    first.value++;
    first.value++;
    expect(heard, ['changed', 'changed']);
  });

  testWidgets('rebuilt with another, it runs once and hears only the new one', (
    tester,
  ) async {
    await show(tester, first);
    await show(tester, second);
    expect(heard, ['changed']);
    first.value++;
    expect(heard, ['changed']);
    second.value++;
    expect(heard, ['changed', 'changed']);
  });

  testWidgets('rebuilt with the same one, it does not run', (tester) async {
    await show(tester, first);
    await show(tester, first);
    expect(heard, isEmpty);
  });

  testWidgets('stopped, it hears nothing, even rebuilt with another', (
    tester,
  ) async {
    await show(tester, first);
    tester.state<_FollowerState>(find.byType(_Follower)).stop();
    first.value++;
    await show(tester, second);
    second.value++;
    expect(heard, isEmpty);
  });

  testWidgets('gone, it hears nothing', (tester) async {
    await show(tester, first);
    await tester.pumpWidget(const SizedBox());
    first.value++;
    expect(heard, isEmpty);
  });
}

class _Follower extends StatefulWidget {
  const _Follower(this.follows, this.heard);
  final Listenable? follows;
  final List<String> heard;
  @override
  State<_Follower> createState() => _FollowerState();
}

class _FollowerState extends State<_Follower> with ListeningState<_Follower> {
  @override
  Listenable? listenableOf(_Follower widget) => widget.follows;

  @override
  void changed() => widget.heard.add('changed');

  void stop() => stopListening();

  @override
  Widget build(BuildContext context) => const SizedBox();
}
