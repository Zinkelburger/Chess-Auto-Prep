import 'dart:async';

import 'package:chess_auto_prep/utils/safe_change_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two symmetrical hazards for a service that widgets listen to: a notify
/// that arrives after its listeners are gone, and one that arrives before the
/// frame that created them has finished building. The mixin covers both.

class _Service extends ChangeNotifier with SafeChangeNotifier {
  int notifications = 0;

  /// The shape that broke both download dialogs: a method whose first act is
  /// to announce a phase, called from a widget's `initState`, so everything
  /// up to its first `await` runs inside the build phase.
  Future<void> start() async {
    notifyListenersOutsideBuild();
    await Future<void>.delayed(Duration.zero);
  }
}

/// Listens the way a card does, and rebuilds on every notification.
class _Listener extends StatefulWidget {
  const _Listener({required this.service});

  final _Service service;

  @override
  State<_Listener> createState() => _ListenerState();
}

class _ListenerState extends State<_Listener> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
    // Deliberately not deferred: this is what the real dialogs do.
    unawaited(widget.service.start());
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    widget.service.notifications++;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a notify raised during a build reaches listeners after it', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.dispose);

    await tester.pumpWidget(MaterialApp(home: _Listener(service: service)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      service.notifications,
      greaterThan(0),
      reason: 'deferring the notify must not swallow it',
    );
  });

  testWidgets('a listener gone before the frame ends is simply not called', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.dispose);

    await tester.pumpWidget(MaterialApp(home: _Listener(service: service)));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  test('it works with no Flutter binding at all', () async {
    // The point of the microtask: a service is used by plain `test()` bodies
    // that never build a widget and never pump a frame. Asking the scheduler
    // which phase it was in killed every one of them.
    final service = _Service();
    var seen = 0;
    service.addListener(() => seen++);

    service.notifyListenersOutsideBuild();
    expect(seen, 0, reason: 'never inside the caller\'s own stack');

    await Future<void>.delayed(Duration.zero);
    expect(seen, 1);
    service.dispose();
  });

  test('nothing is delivered after dispose', () {
    final service = _Service();
    var seen = 0;
    service.addListener(() => seen++);
    service.dispose();

    service.notifyListenersOutsideBuild();

    expect(seen, 0);
    expect(service.isDisposed, isTrue);
  });
}
