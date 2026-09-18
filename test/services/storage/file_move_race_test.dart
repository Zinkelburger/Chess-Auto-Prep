import 'dart:io';

import 'package:chess_auto_prep/services/storage/file_mutation_service.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final unsupported =
      !(Platform.isLinux || Platform.isMacOS || Platform.isWindows);
  late Directory root;
  late File source;
  late File destination;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('exclusive-file-move-');
    source = File(p.join(root.path, 'source.pgn'));
    destination = File(p.join(root.path, 'destination.pgn'));
    await source.writeAsString('source bytes');
  });
  tearDown(() => root.delete(recursive: true));

  test('native exclusive primitive retains both files on collision', () async {
    await destination.writeAsString('external winner');
    await expectLater(
      movePathNoReplace(source.path, destination.path),
      throwsA(isA<NativeNameCollision>()),
    );
    expect(await source.readAsString(), 'source bytes');
    expect(await destination.readAsString(), 'external winner');
  }, skip: unsupported);

  test('exclusive move preserves bytes when destination is free', () async {
    await FileMutationService().moveFileNoReplace(
      source,
      destination,
      allowedRoot: root,
    );
    expect(await source.exists(), isFalse);
    expect(await destination.readAsString(), 'source bytes');
  }, skip: unsupported);

  test(
    'mutation boundary preserves a destination created after preflight',
    () async {
      final race = _DestinationRace(destination);
      Object? failure;
      try {
        await IOOverrides.runWithIOOverrides(
          () => FileMutationService().moveFileNoReplace(
            source,
            destination,
            allowedRoot: root,
          ),
          race,
        );
      } catch (error) {
        failure = error;
      }
      expect(
        race.createdWinner,
        isTrue,
        reason: 'the destination was really absent at the last preflight',
      );
      expect(await destination.readAsString(), 'external winner');
      expect(await source.readAsString(), 'source bytes');
      expect(
        failure,
        isA<FileSystemException>(),
        reason: 'existing caller collision handling must remain compatible',
      );
    },
    skip: unsupported,
  );
}

// Return the real absence observation after an external actor has created the
// destination. The production move still executes its actual filesystem call.
final class _DestinationRace extends IOOverrides {
  _DestinationRace(this.destination);
  final File destination;
  bool createdWinner = false;

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) async {
    final observed = await super.fseGetType(path, followLinks);
    if (path == destination.path && observed == FileSystemEntityType.notFound) {
      await destination.writeAsString('external winner');
      createdWinner = true;
    }
    return observed;
  }
}
