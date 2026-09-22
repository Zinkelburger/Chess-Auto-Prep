import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/features/generation/controllers/generation_recovery_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/models/generation_recovery.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/generation_artifacts_fixture.dart';
import '../../support/legacy_analysis_fixture.dart';

class _Repository extends MemoryGenerationArtifacts {
  final gates = <String, Completer<GenerationRecoverySnapshot>>{};
  final exports = <String>[];
  Object? enumerationError;
  @override
  Future<GenerationRecoveryCatalog> listRecovery(String path) async {
    if (enumerationError case final error?) throw error;
    return GenerationRecoveryCatalog([entry(path), entry('$path-next')]);
  }

  @override
  Future<GenerationRecoverySnapshot> readRecovery(
    GenerationRecoveryEntry entry,
  ) => gates.putIfAbsent(entry.path, Completer.new).future;
  @override
  Future<void> exportRecovery(
    GenerationRecoveryFile file,
    String destination,
  ) async => exports.add(destination);
}

GenerationRecoveryEntry entry(String path) => GenerationRecoveryEntry(
  chapterPath: path,
  id: 'legacy',
  path: path,
  legacy: true,
);
GenerationRecoverySnapshot snapshot(String path) => GenerationRecoverySnapshot(
  entry: entry(path),
  files: [
    for (final value in legacyRecoveryPayloads().entries)
      GenerationRecoveryFile(
        kind: GenerationRecoveryFileKind.values.byName(value.key.name),
        path: '${value.key.name}.json',
        text: value.value,
        bytes: utf8.encode(value.value),
      ),
  ],
);
Future<void> _settleLoad(
  GenerationRecoveryController controller,
  _Repository repository,
  String path,
) async {
  final load = controller.load(path);
  await Future<void>.delayed(Duration.zero);
  repository.gates[path]!.complete(snapshot(path));
  await load;
}

void main() {
  test(
    'enumeration failure retries and picker errors retain export category',
    () async {
      final repository = _Repository()
        ..enumerationError = StateError('listing unavailable');
      final controller = GenerationRecoveryController(
        GenerationArtifacts(repository),
      );
      addTearDown(controller.dispose);
      await controller.load('chapter');
      expect(controller.error?.kind, GenerationArtifactFailureKind.enumerate);
      expect(controller.loading, false);
      repository.enumerationError = null;
      await _settleLoad(controller, repository, 'chapter');
      expect(controller.catalog!.entries, hasLength(2));
      await controller.export(
        controller.inspection!.items.first.file,
        () async => throw StateError('picker unavailable'),
      );
      expect(controller.error?.kind, GenerationArtifactFailureKind.export);
      expect(controller.exporting, false);
      expect(repository.exports, isEmpty);
    },
  );

  test('newer run selection and disposal reject late results', () async {
    final repository = _Repository();
    final controller = GenerationRecoveryController(
      GenerationArtifacts(repository),
    );
    final first = controller.load('first');
    await Future<void>.delayed(Duration.zero);
    final second = controller.select(controller.catalog!.entries.last);
    repository.gates['first-next']!.complete(snapshot('first-next'));
    await second;
    final current = controller.inspection;
    repository.gates['first']!.complete(snapshot('first'));
    await first;
    expect(controller.inspection, same(current));
    final pending = controller.load('third');
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    repository.gates['third']!.complete(snapshot('third'));
    await pending;
    expect(repository.exports, isEmpty);
  });

  test(
    'late picker after disposal cannot export and duplicate clicks are excluded',
    () async {
      final repository = _Repository();
      final controller = GenerationRecoveryController(
        GenerationArtifacts(repository),
      );
      await _settleLoad(controller, repository, 'chapter');
      final file = controller.inspection!.items.first.file;
      final picker = Completer<String?>();
      final export = controller.export(file, () => picker.future);
      await controller.export(file, () async => 'duplicate');
      await controller.select(controller.catalog!.entries.last);
      expect(controller.selected!.path, 'chapter');
      controller.dispose();
      picker.complete('closed');
      await export;
      expect(repository.exports, isEmpty);
    },
  );
}
