// What the fault harness records: one IoOp per filesystem effect under the
// profile root, named by an OpKey that stays the same from run to run.
import 'package:path/path.dart' as p;

/// What an effect does. Reads never change the disk; every other kind is a
/// point a process can be killed at or lose the answer to.
enum IoKind {
  read,
  stat,
  list,

  /// A file created or truncated: `File.create`, or `open` for writing.
  create,
  write,
  mkdir,
  sync,
  syncDir,
  publishReplace,
  publishNew,
  moveNoReplace,
  rename,
  delete,
  copy,
  link;

  bool get reads => this == read || this == stat || this == list;
}

/// `kind:path[->to]#occurrence`, with the paths relative to the root and
/// the times, process ids and random stamps in names replaced, so the same
/// command gives the same keys on every run.
final class OpKey {
  const OpKey(this.kind, this.path, {this.to, this.occurrence = 0});

  final IoKind kind;
  final String path;
  final String? to;

  /// How many earlier effects had this kind and these paths.
  final int occurrence;

  /// The same kind and paths, whichever try it is.
  bool sameEffect(OpKey other) =>
      kind == other.kind && path == other.path && to == other.to;

  @override
  bool operator ==(Object other) =>
      other is OpKey && sameEffect(other) && occurrence == other.occurrence;

  @override
  int get hashCode => Object.hash(kind, path, to, occurrence);

  @override
  String toString() =>
      '${kind.name}:$path${to == null ? '' : '->$to'}#$occurrence';
}

/// One effect as it happened: absolute paths, and its place in the run.
final class IoOp {
  const IoOp(this.index, this.kind, this.path, this.key, {this.to});

  final int index;
  final IoKind kind;
  final String path;
  final String? to;
  final OpKey key;

  @override
  String toString() => '$index $key';
}

/// Numbers the effects under [root] as they happen. A path outside it (the
/// lock databases in the system temporary folder, say) is not recorded.
final class TraceRecorder {
  TraceRecorder(this.root);

  final String root;
  final ops = <IoOp>[];
  final _seen = <String, int>{};

  bool covers(String path) {
    final plain = p.absolute(withoutNamespace(path));
    return p.equals(root, plain) || p.isWithin(root, plain);
  }

  /// The kept-versions folder ids seen, in order.
  final _folders = <String, String>{};

  IoOp? add(IoKind kind, String path, {String? to}) {
    if (!covers(path) && (to == null || !covers(to))) return null;
    final name = _numbered(normalisedPath(root, path));
    final destination = to == null ? null : _numbered(normalisedPath(root, to));
    final effect = '${kind.name}:$name->$destination';
    final occurrence = _seen[effect] ?? 0;
    _seen[effect] = occurrence + 1;
    final key = OpKey(kind, name, to: destination, occurrence: occurrence);
    final op = IoOp(ops.length, kind, path, key, to: to);
    ops.add(op);
    return op;
  }

  /// [name] with each kept-versions folder id, a hash of its document's
  /// path, as the order it was first seen in (`<doc1>`, `<doc2>`…): the
  /// path of a chapter in an import's staging folder, and so its hash,
  /// differs every run, while the order is the command's.
  String _numbered(String name) => name.replaceAllMapped(
    _folderId,
    (id) => _folders.putIfAbsent(id[0]!, () => '<doc${_folders.length + 1}>'),
  );
}

final _folderId = RegExp(
  r'(?<=(?:backups|backup-moves)/(?:[0-9a-f]{16}-)?)[0-9a-f]{16}(?![0-9a-f])',
);

/// [path] relative to [root] with `/` separators, and with the names the
/// stores stamp with the clock, their process id or a random number made
/// the same on every run.
String normalisedPath(String root, String path) =>
    withoutStamps(relativeName(root, path));

/// [text] with the times, process ids and random stamps the stores write
/// made the same on every run: for a name, or for a record that holds one.
String withoutStamps(String text) {
  var plain = text;
  for (final (pattern, replacement) in _stamps) {
    plain = plain.replaceAll(pattern, replacement);
  }
  return plain;
}

/// [path] relative to [root], with `/` separators.
String relativeName(String root, String path) => p
    .split(p.relative(p.absolute(withoutNamespace(path)), from: root))
    .join('/');

/// [path] without the `\\?\` prefix Windows long-path listings carry, so a
/// listed entry has the name the caller asked for.
String withoutNamespace(String path) {
  if (path.startsWith(r'\\?\UNC\')) return r'\\' + path.substring(8);
  if (path.startsWith(r'\\?\')) return path.substring(4);
  return path;
}

final _stamps = [
  // Windows' ReplaceFileW recovery copy: `.previous-<pid>-<µs>`.
  (RegExp(r'\.previous-\d+-\d+'), '.previous-<pid>-<time>'),
  // Kept versions and quarantine folders: `20260929T101112123456Z`.
  (RegExp(r'\d{8}T\d{6,12}Z'), '<time>'),
  // Times recorded inside a kept version's index: `2026-09-29T10:11:12Z`.
  (RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?'), '<time>'),
  // settings.json set aside: `2026-09-29T10-11-12.123Z`.
  (RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(\.\d+)?Z'), '<time>'),
  // Journal and note ids: `<µs since epoch>-<random hex>`.
  (RegExp(r'\d{13,}-[0-9a-f]{1,8}(?![0-9A-Za-z])'), '<id>'),
  // Import staging folders: `.import-<µs in base 36>`.
  (RegExp(r'\.import-[0-9a-z]+'), '.import-<id>'),
  // Not digits inside a hex id, such as the kept-versions id of a staging
  // folder's chapter, which differs between runs.
  (RegExp(r'(?<![0-9a-f])\d{13,}(?![0-9a-f])'), '<time>'),
];
