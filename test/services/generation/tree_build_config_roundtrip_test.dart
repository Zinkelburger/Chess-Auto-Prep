import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/generation/generation_config.dart';

/// Drift guard for [TreeBuildConfig]'s five-place field contract.
///
/// The class carries ~60 knobs, and adding one means editing the field list,
/// the constructor, `fromJson`, `toJson` and `copyWith` — five places, with
/// nothing but discipline holding them together. A field forgotten in
/// `fromJson` silently reverts to its default every time a saved config is
/// reloaded; forgotten in `toJson` it never persists at all. Both failures are
/// invisible at the call site and survive every existing test.
///
/// Rather than enumerate the fields (a list that would drift in exactly the
/// same way), these tests drive the serialized map generically: take a real
/// config's JSON, change *every* value, round-trip it, and require the result
/// to have kept every change.
const String _startFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Keys whose values are enum names — mutating these to arbitrary strings
/// would hit the parsers' `default:` fallback and look like a lost field, so
/// each maps to a *different but valid* member of its own enum.
const Map<String, String> _enumAlternatives = {
  'search_algorithm': 'pure',
  'build_mode': 'dbExplorer',
  'selection_mode': 'trappy',
  'annotation_detail': 'none',
};

/// Keys deliberately exempt from the round-trip identity check.
const Map<String, String> _knownLossy = {
  // toJson writes `resolvedEngineThreads` — the value clamped to *this*
  // machine's core count — rather than the raw field, so the 0 = "auto"
  // sentinel does not survive a save. That is intentional: a resumed build
  // reuses the thread count it was actually built with instead of silently
  // re-resolving to a different number on different hardware.
  'engine_threads': 'serialized as the resolved value, not the raw sentinel',
};

/// Produce a value of the same type as [value] but guaranteed different.
Object? _mutate(String key, Object? value) {
  final enumAlt = _enumAlternatives[key];
  if (enumAlt != null) return enumAlt;
  if (value is bool) return !value;
  if (value is int) return value + 7;
  if (value is double) return value + 0.125;
  if (value is String) return '${value}_x';
  if (value is List) return [...value.cast<String>(), 'added.pgn'];
  return value;
}

void main() {
  group('TreeBuildConfig serialization contract', () {
    test('every serialized field survives a toJson → fromJson round-trip', () {
      const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      final baseline = original.toJson();

      // Change every single value, so a field dropped from either direction
      // shows up as a value that reverted to the original.
      final mutated = <String, dynamic>{
        for (final entry in baseline.entries)
          entry.key: _mutate(entry.key, entry.value),
      };

      final restored = TreeBuildConfig.fromJson(
        mutated,
        startFen: _startFen,
      ).toJson();

      final lost = <String>[];
      for (final key in mutated.keys) {
        if (_knownLossy.containsKey(key)) continue;
        // Lists compare by identity in Dart, so compare their contents.
        final before = mutated[key], after = restored[key];
        final same = before is List && after is List
            ? before.length == after.length &&
                  List.generate(
                    before.length,
                    (i) => before[i] == after[i],
                  ).every((e) => e)
            : before == after;
        if (!same) lost.add(key);
      }

      expect(
        lost,
        isEmpty,
        reason:
            'These keys did not survive the round-trip. Each is either missing '
            'from fromJson (so it reset to its default) or written by toJson '
            'under a different key than fromJson reads:\n'
            '${lost.map((k) => '  $k: wrote ${mutated[k]}, read back ${restored[k]}').join('\n')}',
      );
    });

    test('annotation_detail accepts every one of its own names', () {
      // The enum alternative above is only meaningful if the parser really
      // round-trips names; a silent fallback would hide a lost field.
      for (final detail in MoveAnnotationDetail.values) {
        final json = const TreeBuildConfig(
          startFen: _startFen,
          playAsWhite: true,
        ).toJson()..['annotation_detail'] = detail.name;
        final parsed = TreeBuildConfig.fromJson(json, startFen: _startFen);
        expect(parsed.annotationDetail, detail);
      }
    });

    test('startFen is supplied out of band, not through the map', () {
      const config = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      expect(
        config.toJson().containsKey('start_fen'),
        isFalse,
        reason:
            'startFen is a required fromJson argument; serializing it too '
            'would create a second source of truth for the build root.',
      );
    });
  });

  group('TreeBuildConfig copyWith contract', () {
    test('copyWith with no arguments is an exact copy', () {
      const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      expect(
        jsonEncode(original.copyWith().toJson()),
        jsonEncode(original.toJson()),
      );
    });

    test('copyWith can change every serialized field', () {
      // Mirrors the round-trip test for the other mutation path: build a fully
      // mutated config through fromJson, then confirm copyWith() preserves it
      // rather than resetting fields it forgot to carry over.
      const original = TreeBuildConfig(startFen: _startFen, playAsWhite: true);
      final mutated = <String, dynamic>{
        for (final entry in original.toJson().entries)
          entry.key: _mutate(entry.key, entry.value),
      };
      final loaded = TreeBuildConfig.fromJson(mutated, startFen: _startFen);

      // Compare through jsonEncode so list values compare structurally.
      expect(
        jsonEncode(loaded.copyWith().toJson()),
        jsonEncode(loaded.toJson()),
        reason:
            'copyWith() dropped a field: it is missing from the parameter list '
            'or from the constructor call in its body.',
      );
    });
  });
}
