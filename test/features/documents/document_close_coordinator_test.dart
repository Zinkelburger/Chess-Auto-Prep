import 'dart:async';
import 'package:chess_auto_prep/features/documents/controllers/document_close_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DocumentCloseCoordinator coordinator;
  setUp(() => coordinator = DocumentCloseCoordinator());
  tearDown(() => coordinator.dispose());

  test('clean or saved documents approve one shared close attempt', () async {
    final pending = Completer<DocumentCloseApproval?>();
    var calls = 0;
    coordinator.register(
      key: 'study',
      revision: () => 1,
      prepare: () {
        calls++;
        return pending.future;
      },
    );
    final first = coordinator.prepareClose();
    final second = coordinator.prepareClose();
    expect(second, same(first));
    pending.complete(const DocumentCloseApproval(1));
    expect((await first).disposition, DocumentCloseDisposition.approved);
    expect(calls, 1);
  });
  test('a cancellation stops later owners and permits a new attempt', () async {
    var cancel = true;
    var later = 0;
    coordinator.register(
      key: 'first',
      revision: () => 1,
      prepare: () async => cancel ? null : const DocumentCloseApproval(1),
    );
    coordinator.register(
      key: 'later',
      revision: () => 2,
      prepare: () async {
        later++;
        return const DocumentCloseApproval(2);
      },
    );
    expect(
      (await coordinator.prepareClose()).disposition,
      DocumentCloseDisposition.cancelled,
    );
    expect(later, 0);
    cancel = false;
    expect(
      (await coordinator.prepareClose()).disposition,
      DocumentCloseDisposition.approved,
    );
    expect(later, 1);
  });
  test(
    'an earlier document edited while a later owner is saving invalidates approval',
    () async {
      var revision = 1;
      coordinator.register(
        key: 'first',
        revision: () => revision,
        prepare: () async => DocumentCloseApproval(revision),
      );
      coordinator.register(
        key: 'second',
        revision: () => 1,
        prepare: () async {
          revision++;
          return const DocumentCloseApproval(1);
        },
      );
      expect(
        (await coordinator.prepareClose()).disposition,
        DocumentCloseDisposition.changed,
      );
    },
  );
  test(
    'opening or removing an owner during confirmation requires a new attempt',
    () async {
      final pending = Completer<DocumentCloseApproval?>();
      final remove = coordinator.register(
        key: 'first',
        revision: () => 1,
        prepare: () => pending.future,
      );
      final closing = coordinator.prepareClose();
      await Future<void>.delayed(Duration.zero);
      remove();
      coordinator.register(
        key: 'new',
        revision: () => 1,
        prepare: () async => const DocumentCloseApproval(1),
      );
      pending.complete(const DocumentCloseApproval(1));
      expect((await closing).disposition, DocumentCloseDisposition.changed);
      expect(
        (await coordinator.prepareClose()).disposition,
        DocumentCloseDisposition.approved,
      );
    },
  );
  test(
    'failed persistence cannot approve and does not poison the next attempt',
    () async {
      var fail = true;
      coordinator.register(
        key: 'owner',
        revision: () => 1,
        prepare: () async {
          if (fail) throw StateError('disk');
          return const DocumentCloseApproval(1);
        },
      );
      expect(
        (await coordinator.prepareClose()).disposition,
        DocumentCloseDisposition.failed,
      );
      fail = false;
      expect(
        (await coordinator.prepareClose()).disposition,
        DocumentCloseDisposition.approved,
      );
    },
  );
  test('unmount during save cannot authorize native closure', () async {
    final pending = Completer<DocumentCloseApproval?>();
    coordinator.register(
      key: 'owner',
      revision: () => 1,
      prepare: () => pending.future,
    );
    final closing = coordinator.prepareClose();
    await Future<void>.delayed(Duration.zero);
    coordinator.dispose();
    pending.complete(const DocumentCloseApproval(1));
    expect((await closing).disposition, DocumentCloseDisposition.cancelled);
  });
}
