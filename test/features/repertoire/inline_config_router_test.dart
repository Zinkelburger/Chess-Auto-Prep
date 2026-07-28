import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/controllers/inline_config_router.dart';

void main() {
  late InlineConfigRouter router;

  setUp(() => router = InlineConfigRouter());

  test('starts with neither form open', () {
    expect(router.showGeneration, isFalse);
    expect(router.showAudit, isFalse);
    expect(router.anyOpen, isFalse);
  });

  group('generation', () {
    test('opens on the Jobs tab', () {
      expect(router.openGeneration(), InlineConfigTarget.jobs);
      expect(router.showGeneration, isTrue);
    });

    test('replaces the audit form — they share one tab', () {
      router.openAudit(auditHasSomethingToShow: false);
      router.openGeneration();

      expect(router.showGeneration, isTrue);
      expect(router.showAudit, isFalse);
    });

    test('a started build takes its own form down, once', () {
      router.openGeneration();

      expect(router.onGenerationStarted(), isTrue);
      expect(router.showGeneration, isFalse);
      // Idempotent: the listener fires on every progress tick.
      expect(router.onGenerationStarted(), isFalse);
    });
  });

  group('audit', () {
    test('opens the config when there is nothing to show yet', () {
      expect(
        router.openAudit(auditHasSomethingToShow: false),
        InlineConfigTarget.jobs,
      );
      expect(router.showAudit, isTrue);
    });

    test('shows findings instead when a run is under way or done', () {
      expect(
        router.openAudit(auditHasSomethingToShow: true),
        InlineConfigTarget.findings,
      );
      // And it does not quietly arm the config form behind the findings.
      expect(router.showAudit, isFalse);
    });

    test('forceConfig gets the form back even with results waiting', () {
      expect(
        router.openAudit(auditHasSomethingToShow: true, forceConfig: true),
        InlineConfigTarget.jobs,
      );
      expect(router.showAudit, isTrue);
    });

    test('replaces the generation form', () {
      router.openGeneration();
      router.openAudit(auditHasSomethingToShow: false);

      expect(router.showAudit, isTrue);
      expect(router.showGeneration, isFalse);
    });

    test('a started audit takes its own form down, once', () {
      router.openAudit(auditHasSomethingToShow: false);

      expect(router.onAuditStarted(), isTrue);
      expect(router.showAudit, isFalse);
      expect(router.onAuditStarted(), isFalse);
    });
  });

  group('clear', () {
    test('closes whatever was open and reports that it did', () {
      router.openGeneration();

      expect(router.clear(), isTrue);
      expect(router.anyOpen, isFalse);
    });

    test('reports nothing to do when both forms are already closed', () {
      expect(router.clear(), isFalse);
    });
  });
}
