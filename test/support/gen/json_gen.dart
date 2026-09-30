/// JSON for the codec laws: random values, the unknown fields a newer build
/// or the other app may add to a file this build reads, and damage to a
/// decoded document.
///
/// Every value is plain decoded JSON — maps with string keys, lists,
/// strings, numbers, booleans and null — so it survives `jsonEncode` and
/// compares with [sameJson].
library;

import 'package:collection/collection.dart';

import '../props.dart';

/// Strings a file may hold: empty, padded, quoted, escaped, non-ASCII, and
/// ones that look like paths, numbers or other JSON.
const jsonStrings = [
  '',
  ' ',
  'plain',
  'with "quotes"',
  r'back\slash',
  'line\nbreak',
  'tab\there',
  'Не лучший ход',
  '½ → ∞ ♞',
  'KID/Main.pgn',
  '42',
  'true',
  'null',
  '{"not": "an object"}',
];

/// Any JSON value, nested at most [depth] levels.
Object? jsonValue(Rand rand, {int depth = 2}) {
  switch (rand.nextInt(depth > 0 ? 8 : 6)) {
    case 0:
      return null;
    case 1:
      return rand.nextBool();
    case 2:
      return rand.between(-1000000, 1000000);
    case 3:
      return rand.pick(const [0.5, -1.25, 1e-9, 123456.789, 0.1, 1e21]);
    case 4:
    case 5:
      return rand.pick(jsonStrings);
    case 6:
      return [
        for (var i = rand.between(0, 3); i > 0; i--)
          jsonValue(rand, depth: depth - 1),
      ];
    default:
      return <String, Object?>{
        for (var i = rand.between(0, 3); i > 0; i--)
          'k$i${rand.pick(const ['', '_x', ' y'])}': jsonValue(
            rand,
            depth: depth - 1,
          ),
      };
  }
}

/// A copy of [json] with fields no reader knows added to every object in
/// it, at every depth, each named `x_<n>` and holding any JSON value. About
/// one object in three is left without; [every] adds to all of them.
Object? withUnknownFields(Object? json, Rand rand, {bool every = false}) {
  var next = 0;
  Object? walk(Object? value) => switch (value) {
    Map<String, Object?>() => <String, Object?>{
      for (final entry in value.entries) entry.key: walk(entry.value),
      if (every || !rand.chance(33))
        for (var i = rand.between(1, 2); i > 0; i--)
          'x_${next++}': jsonValue(rand),
    },
    List<Object?>() => [for (final item in value) walk(item)],
    _ => value,
  };
  return walk(json);
}

/// Whether [a] and [b] are the same JSON, key order aside.
bool sameJson(Object? a, Object? b) =>
    const DeepCollectionEquality().equals(a, b);

/// Every place in [json] a value sits, as the keys and indexes that lead to
/// it; the root itself is the empty path.
List<List<Object>> jsonPaths(Object? json) {
  final paths = <List<Object>>[];
  void walk(Object? value, List<Object> path) {
    paths.add(path);
    if (value is Map<String, Object?>) {
      for (final key in value.keys) {
        walk(value[key], [...path, key]);
      }
    } else if (value is List<Object?>) {
      for (var i = 0; i < value.length; i++) {
        walk(value[i], [...path, i]);
      }
    }
  }

  walk(json, const []);
  return paths;
}

/// A deep copy of [json] with the value at [path] given to [change], which
/// returns its replacement. Null from [change] under an object takes the
/// key out, and under a list takes the item out; [remove] says which.
Object? atPath(
  Object? json,
  List<Object> path,
  Object? Function(Object? value) change, {
  bool remove = false,
}) {
  if (path.isEmpty) return change(json);
  final [head, ...rest] = path;
  switch (json) {
    case Map<String, Object?>():
      final copy = Map<String, Object?>.of(json);
      final next = atPath(copy[head], rest, change, remove: remove);
      if (remove && rest.isEmpty) {
        copy.remove(head);
      } else {
        copy[head as String] = next;
      }
      return copy;
    case List<Object?>():
      final copy = List<Object?>.of(json);
      final at = head as int;
      if (remove && rest.isEmpty) {
        copy.removeAt(at);
      } else {
        copy[at] = atPath(copy[at], rest, change, remove: remove);
      }
      return copy;
    default:
      return json;
  }
}

/// One way to damage a decoded document, by name so a failure says which.
typedef JsonMutation = ({
  String name,
  Object? Function(Object? json, Rand rand) apply,
});

/// Damage a document can take and still be JSON: a value lost, replaced by
/// any other, given another type, a number made extreme, or a list emptied.
final List<JsonMutation> jsonMutations = [
  (
    name: 'drop a value',
    apply: (json, r) => _somewhere(json, r, (_) => null, remove: true),
  ),
  (
    name: 'replace a value',
    apply: (json, r) => _somewhere(json, r, (_) => jsonValue(r)),
  ),
  (name: 'retype a value', apply: (json, r) => _somewhere(json, r, _retyped)),
  (
    name: 'extreme number',
    apply: (json, r) => _somewhere(
      json,
      r,
      (_) => r.pick(const [-1, 0, 1e308, -1e308, 9007199254740993, 0.5]),
    ),
  ),
  (
    name: 'empty a collection',
    apply: (json, r) => _somewhere(
      json,
      r,
      (v) => v is List ? const <Object?>[] : (v is Map ? const {} : v),
    ),
  ),
];

/// [json] with 1 to [most] of [jsonMutations] applied, and their names.
({Object? json, List<String> applied}) mutateJson(
  Object? json,
  Rand rand, {
  int most = 3,
}) {
  var result = json;
  final applied = <String>[];
  for (var i = rand.between(1, most); i > 0; i--) {
    final mutation = rand.pick(jsonMutations);
    result = mutation.apply(result, rand);
    applied.add(mutation.name);
  }
  return (json: result, applied: applied);
}

Object? _somewhere(
  Object? json,
  Rand rand,
  Object? Function(Object? value) change, {
  bool remove = false,
}) {
  final paths = jsonPaths(json).where((p) => p.isNotEmpty).toList();
  if (paths.isEmpty) return change(json);
  return atPath(json, rand.pick(paths), change, remove: remove);
}

/// The same content under another JSON type: a number as a string, a
/// string as a list of it, a boolean as a number, a collection as null.
Object? _retyped(Object? value) => switch (value) {
  num() => '$value',
  String() => [value],
  bool() => value ? 1 : 0,
  null => false,
  _ => null,
};
