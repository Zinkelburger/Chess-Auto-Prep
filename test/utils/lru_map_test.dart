import 'package:chess_auto_prep/utils/lru_map.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LruMap', () {
    test('holds entries up to the cap', () {
      final map = LruMap<String, int>(maxEntries: 3);
      map['a'] = 1;
      map['b'] = 2;
      map['c'] = 3;

      expect(map.length, 3);
      expect(map['a'], 1);
      expect(map['c'], 3);
    });

    test('drops the oldest entry once past the cap', () {
      final map = LruMap<String, int>(maxEntries: 2);
      map['a'] = 1;
      map['b'] = 2;
      map['c'] = 3;

      expect(map.length, 2);
      expect(map['a'], isNull);
      expect(map['b'], 2);
      expect(map['c'], 3);
    });

    test('a read saves an entry from the next eviction', () {
      final map = LruMap<String, int>(maxEntries: 2);
      map['a'] = 1;
      map['b'] = 2;

      // 'a' is the oldest insertion, but reading it makes it the newest use.
      expect(map['a'], 1);
      map['c'] = 3;

      expect(map['a'], 1, reason: 'the read should have promoted it');
      expect(map['b'], isNull, reason: 'b is now the least recently used');
    });

    test('peek reads without changing the eviction order', () {
      final map = LruMap<String, int>(maxEntries: 2);
      map['a'] = 1;
      map['b'] = 2;

      expect(map.peek('a'), 1);
      map['c'] = 3;

      expect(map.peek('a'), isNull, reason: 'peek must not promote');
      expect(map.peek('b'), 2);
    });

    test('re-writing a key refreshes it rather than adding a second entry', () {
      final map = LruMap<String, int>(maxEntries: 2);
      map['a'] = 1;
      map['b'] = 2;
      map['a'] = 10;

      expect(map.length, 2);
      map['c'] = 3;

      expect(map['a'], 10);
      expect(map['b'], isNull);
    });

    test('putIfAbsent inserts once and promotes on a hit', () {
      final map = LruMap<String, int>(maxEntries: 2);

      expect(map.putIfAbsent('a', () => 1), 1);
      map['b'] = 2;
      // A hit must not call the factory, and must refresh recency.
      expect(map.putIfAbsent('a', () => fail('should not be called')), 1);

      map['c'] = 3;
      expect(map['a'], 1);
      expect(map['b'], isNull);
    });

    test('putIfAbsent evicts when the insert goes over the cap', () {
      final map = LruMap<String, int>(maxEntries: 2);
      map['a'] = 1;
      map['b'] = 2;
      map.putIfAbsent('c', () => 3);

      expect(map.length, 2);
      expect(map['a'], isNull);
    });

    test('a null value is a present entry, not a miss', () {
      final map = LruMap<String, int?>(maxEntries: 2);
      map['a'] = null;
      map['b'] = 2;

      expect(map.containsKey('a'), isTrue);
      // Reading it must still promote, even though the value reads as null.
      expect(map['a'], isNull);
      map['c'] = 3;
      expect(map.containsKey('a'), isTrue);
      expect(map.containsKey('b'), isFalse);
    });

    test('remove and clear', () {
      final map = LruMap<String, int>(maxEntries: 3);
      map['a'] = 1;
      map['b'] = 2;

      expect(map.remove('a'), 1);
      expect(map.remove('a'), isNull);
      expect(map.length, 1);
      expect(map.isNotEmpty, isTrue);

      map.clear();
      expect(map.isEmpty, isTrue);
      expect(map.length, 0);
    });

    test('keys come back oldest first, which is eviction order', () {
      final map = LruMap<String, int>(maxEntries: 3);
      map['a'] = 1;
      map['b'] = 2;
      map['c'] = 3;
      map['a'] = 1; // refreshed, so it moves to the back

      expect(map.keys.toList(), ['b', 'c', 'a']);
      expect(map.values.toList(), [2, 3, 1]);
      expect(map.entries.map((e) => e.key).toList(), ['b', 'c', 'a']);
    });

    test('holds steady under many more writes than the cap', () {
      final map = LruMap<int, int>(maxEntries: 10);
      for (var i = 0; i < 10000; i++) {
        map[i] = i;
      }

      expect(map.length, 10);
      expect(map.keys.first, 9990);
      expect(map[9999], 9999);
      expect(map[0], isNull);
    });
  });
}
