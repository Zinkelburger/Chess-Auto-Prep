import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';

void main() {
  group('RepertoireMetadata', () {
    test('toMap and fromMap round-trip', () {
      final now = DateTime(2025, 6, 15, 12, 0);
      final original = RepertoireMetadata(
        filePath: '/data/sicilian.pgn',
        name: 'Sicilian Defense',
        gameCount: 42,
        lastModified: now,
      );

      final map = original.toMap();
      final restored = RepertoireMetadata.fromMap(map);

      expect(restored.filePath, original.filePath);
      expect(restored.name, original.name);
      expect(restored.gameCount, original.gameCount);
      expect(restored.lastModified, original.lastModified);
    });

    test('fromMap uses defaults for missing optional fields', () {
      final meta = RepertoireMetadata.fromMap({
        'filePath': '/test.pgn',
        'name': 'Test',
      });

      expect(meta.gameCount, 0);
      expect(meta.lastModified, isA<DateTime>());
    });

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
