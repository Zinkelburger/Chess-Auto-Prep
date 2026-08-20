import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/controllers/audit_entry_router.dart';

void main() {
  const router = AuditEntryRouter();

  test('opens the config when there is nothing to show yet', () {
    expect(router.resolve(auditHasSomethingToShow: false), AuditEntry.config);
  });

  test('shows findings instead when a run is under way or done', () {
    expect(router.resolve(auditHasSomethingToShow: true), AuditEntry.findings);
  });

  test('forceConfig gets the form back even with results waiting', () {
    expect(
      router.resolve(auditHasSomethingToShow: true, forceConfig: true),
      AuditEntry.config,
    );
  });

  test('forceConfig is a no-op when there was nothing to show anyway', () {
    expect(
      router.resolve(auditHasSomethingToShow: false, forceConfig: true),
      AuditEntry.config,
    );
  });
}
