import 'package:chess_auto_prep/features/audit/services/repertoire_audit_service.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../../support/runtime_settings.dart';
import 'package:chess_auto_prep/features/audit/controllers/audit_session_controller.dart';
import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

AuditFinding _finding() => AuditFinding(
  type: AuditFindingType.mistake,
  severity: AuditSeverity.warning,
  movePath: const [],
  fen: _startFen,
  ourMove: 'e4',
);

AuditResult _result(List<AuditFinding> findings) => AuditResult(
  findings: findings,
  nodesChecked: findings.length,
  ourMoveNodesChecked: 0,
  opponentNodesChecked: 0,
  leafNodesChecked: 0,
  elapsed: Duration.zero,
);

/// Views cache work derived from the findings — the board's audit arrows are
/// memoised per position.  They cannot key that cache on the result object,
/// because dismissing a finding edits it in place and hands the same object
/// back; [AuditSessionController.resultVersion] is what tells them apart.
RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  test('an in-place edit re-emitted as the same object bumps the version', () {
    final controller = AuditSessionController(
      service: RepertoireAuditService(pool: engines.pool),
      prepareEngine: () => engines.lifecycle.enterGeneration(1),
      releaseEngine: engines.lifecycle.exitGeneration,
    );
    final finding = _finding();
    final result = _result([finding]);

    controller.onResultChanged(result, null);
    final afterLoad = controller.resultVersion;
    expect(identical(controller.result, result), isTrue);

    // What the findings panel does on dismiss: mutate, then re-emit the very
    // same result.
    finding.dismissed = true;
    controller.onResultChanged(result, null);

    expect(identical(controller.result, result), isTrue);
    expect(
      controller.resultVersion,
      greaterThan(afterLoad),
      reason: 'the object never changed, but what it means did',
    );
    controller.dispose();
  });

  test('replacing the result bumps it too', () {
    final controller = AuditSessionController(
      service: RepertoireAuditService(pool: engines.pool),
      prepareEngine: () => engines.lifecycle.enterGeneration(1),
      releaseEngine: engines.lifecycle.exitGeneration,
    );
    controller.onResultChanged(_result([_finding()]), null);
    final before = controller.resultVersion;

    controller.onResultChanged(_result([]), null);

    expect(controller.resultVersion, greaterThan(before));
    controller.dispose();
  });

  test('a read does not bump it', () {
    final controller = AuditSessionController(
      service: RepertoireAuditService(pool: engines.pool),
      prepareEngine: () => engines.lifecycle.enterGeneration(1),
      releaseEngine: engines.lifecycle.exitGeneration,
    );
    controller.onResultChanged(_result([_finding()]), null);
    final version = controller.resultVersion;

    controller.result;
    controller.result?.findings.length;

    expect(controller.resultVersion, version);
    controller.dispose();
  });
}
