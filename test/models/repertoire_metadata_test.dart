import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';

void main() {
  group('RepertoireMetadata', () {
    test('equality based on filePath', () {
      final a = RepertoireMetadata(
        filePath: '/data/test.pgn',
        name: 'A',
        lastModified: DateTime(2025),
      );
      final b = RepertoireMetadata(
        filePath: '/data/test.pgn',
        name: 'B',
        gameCount: 10,
        lastModified: DateTime(2026),
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality for different paths', () {
      final a = RepertoireMetadata(
        filePath: '/data/a.pgn',
        name: 'A',
        lastModified: DateTime(2025),
      );
      final b = RepertoireMetadata(
        filePath: '/data/b.pgn',
        name: 'A',
        lastModified: DateTime(2025),
      );

      expect(a, isNot(equals(b)));
    });

    test('copyWith preserves unchanged fields', () {
      final original = RepertoireMetadata(
        filePath: '/data/test.pgn',
        name: 'Original',
        gameCount: 5,
        lastModified: DateTime(2025),
      );

      final updated = original.copyWith(name: 'Updated', gameCount: 10);

      expect(updated.filePath, original.filePath);
      expect(updated.name, 'Updated');
      expect(updated.gameCount, 10);
      expect(updated.lastModified, original.lastModified);
    });
  });
}
