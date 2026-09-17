import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/features/generation/controllers/legacy_analysis_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/generation_artifacts_fixture.dart';
import '../../support/legacy_analysis_fixture.dart';

class _Repository extends MemoryGenerationArtifacts {
  final gates = <String, Completer<GenerationArtifactSnapshot>>{};
  final exports = <String>[];
  @override
  Future<GenerationArtifactSnapshot> readLegacy(String path) =>
      gates.putIfAbsent(path, Completer.new).future;
  @override
  Future<void> exportLegacy(
    GenerationArtifactSnapshot snapshot,
    GenerationArtifactKind kind,
    String destination,
  ) async => exports.add(destination);
}

GenerationArtifactSnapshot snapshot() => GenerationArtifactSnapshot(
  origin: GenerationArtifactOrigin.legacy,
  payloads: legacyRecoveryPayloads(),
  originalBytes: {
    for (final entry in legacyRecoveryPayloads().entries)
      entry.key: utf8.encode(entry.value),
  },
);
void main() {
  test('newer selection and disposal reject late legacy results', () async {
    final repository = _Repository();
    final controller = LegacyAnalysisController(
      GenerationArtifacts(repository),
    );
    final first = controller.load('first');
    final second = controller.load('second');
    repository.gates['second']!.complete(snapshot());
    await second;
    final current = controller.inspection;
    repository.gates['first']!.complete(snapshot());
    await first;
    expect(controller.inspection, same(current));
    final pending = controller.load('third');
    controller.dispose();
    repository.gates['third']!.complete(snapshot());
    await pending;
    expect(repository.active, isEmpty);
  });
  test(
    'closing during picker prevents export and duplicate clicks share one command',
    () async {
      final repository = _Repository();
      final controller = LegacyAnalysisController(
        GenerationArtifacts(repository),
      );
      final load = controller.load('chapter');
      repository.gates['chapter']!.complete(snapshot());
      await load;
      final picker = Completer<String?>();
      final export = controller.export(
        GenerationArtifactKind.tree,
        () => picker.future,
      );
      await controller.export(
        GenerationArtifactKind.tree,
        () async => 'duplicate',
      );
      controller.dispose();
      picker.complete('closed');
      await export;
      expect(repository.exports, isEmpty);
    },
  );
}
