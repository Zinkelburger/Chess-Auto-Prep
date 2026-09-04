import 'package:chess_auto_prep/widgets/storage_destination_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The picker is handed its size *after* it is first built — both database
/// dialogs probe the published manifest over the network and rebuild when the
/// answer lands. That rebuild used to run `onChanged` straight out of
/// `didUpdateWidget`, i.e. during the build phase, and every host answers
/// `onChanged` with a `setState`. The result was "setState() called during
/// build" and a red error box where the drive list should be, on the only
/// path a user ever takes.
///
/// [_Host] is the shape of both real hosts: it holds the destination in state
/// and sets it from the callback.
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int? _requiredBytes;
  StorageDestination? _destination;

  /// What a resolved size probe does to the host.
  void resolveSize() =>
      setState(() => _requiredBytes = 20 * 1000 * 1000 * 1000);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StorageDestinationPicker(
            requiredBytes: _requiredBytes,
            folderName: 'test-db',
            browseTitle: 'Pick a folder',
            onChanged: (d) => setState(() => _destination = d),
          ),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a size arriving after the first build does not throw', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    // Let the drive listing land, so the size is genuinely the second thing
    // to arrive — the order the real dialogs see.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.state<_HostState>(find.byType(_Host)).resolveSize();
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'onChanged must not reach the host during its own build',
    );
  });

  testWidgets('the host still hears about the size it just supplied', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    final host = tester.state<_HostState>(find.byType(_Host));
    host.resolveSize();
    await tester.pumpAndSettle();

    // Deferring the callback must not drop it: the Download button is gated
    // on the host having a destination, so a swallowed notify is a dialog
    // that can never be confirmed.
    expect(host._destination, isNotNull);
  });

  testWidgets('a dialog closed on the same frame as its size does not throw', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    tester.state<_HostState>(find.byType(_Host)).resolveSize();
    // Unmount before the post-frame callback runs.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
