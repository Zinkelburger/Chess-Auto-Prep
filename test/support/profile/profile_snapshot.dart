// A whole profile at one moment, bytes and all, so the contracts can
// compare states after the disk has moved on: what changed, what the system
// of record holds (the projection), and a text diff for a failure report.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../faulty_disk/faulty_disk.dart' show onRealDisk;
import 'authority.dart';
import 'profile.dart';

sealed class SnapshotEntry {
  const SnapshotEntry();

  /// What the entry is, short enough to compare: `dir`, `link <target>` or
  /// `file <sha256>`.
  String get digest;
}

final class DirectoryEntry extends SnapshotEntry {
  const DirectoryEntry();

  @override
  String get digest => 'dir';
}

final class LinkEntry extends SnapshotEntry {
  const LinkEntry(this.target);
  final String target;

  @override
  String get digest => 'link $target';
}

final class FileEntry extends SnapshotEntry {
  FileEntry(this.bytes) : hash = '${sha256.convert(bytes)}';
  final Uint8List bytes;
  final String hash;

  @override
  String get digest => 'file $hash';
}

final class ProfileSnapshot {
  const ProfileSnapshot._(this.root, this.entries);

  /// Every entry under [profile] now. Taken on the real disk, so it may be
  /// called while a FaultyDisk run is frozen or from inside one.
  factory ProfileSnapshot.of(Profile profile) =>
      onRealDisk(() => ProfileSnapshot._(profile.root, _walk(profile.root)));

  final String root;

  /// By path relative to [root], `/` between the parts, in sorted order.
  final SplayTreeMap<String, SnapshotEntry> entries;

  Authority classOf(String name) =>
      classify(name, directory: entries[name] is DirectoryEntry);

  /// The files and links of [authority], by name.
  List<String> filesOf(Authority authority) => [
    for (final MapEntry(:key, :value) in entries.entries)
      if (value is! DirectoryEntry && classOf(key) == authority) key,
  ];

  /// The system of record: each authoritative file or link and its digest.
  /// Folders are left out (an empty one holds no data), and so are SQLite's
  /// files, whose atomicity is SQLite's own. Throws for an entry the
  /// Authority table does not name.
  Map<String, String> get projection => {
    for (final name in filesOf(Authority.authoritative))
      if (!sqliteManaged(name)) name: entries[name]!.digest,
  };

  /// Journal records still waiting to be finished.
  List<String> get pending => filesOf(Authority.journal);

  /// What recovery set aside under `Support/recovery-quarantine/`.
  List<String> get quarantine => [
    for (final name in filesOf(Authority.recovery))
      if (quarantined(name)) name,
  ];

  Uint8List? bytes(String name) => switch (entries[name]) {
    FileEntry(:final bytes) => bytes,
    _ => null,
  };

  String? text(String name) {
    final bytes = this.bytes(name);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// [relative] to the profile root, for an absolute [path] under it.
  String nameOf(String path) => p.split(p.relative(path, from: root)).join('/');

  /// The entries that are new, gone or different since [before].
  List<String> changedFrom(ProfileSnapshot before) => [
    for (final name in {...before.entries.keys, ...entries.keys})
      if (before.entries[name]?.digest != entries[name]?.digest) name,
  ]..sort();
}

SplayTreeMap<String, SnapshotEntry> _walk(String root) {
  final entries = SplayTreeMap<String, SnapshotEntry>();
  final folder = Directory(root);
  if (!folder.existsSync()) return entries;
  for (final entry in folder.listSync(recursive: true, followLinks: false)) {
    final name = p.split(p.relative(entry.path, from: root)).join('/');
    entries[name] = switch (entry) {
      Link() => LinkEntry(entry.targetSync()),
      Directory() => const DirectoryEntry(),
      File() => FileEntry(entry.readAsBytesSync()),
      _ => throw StateError('unexpected entry $name'),
    };
  }
  return entries;
}

/// What differs from [before] to [after], one line per entry — `+` new,
/// `-` gone, `~` changed — and, under a changed file, the lines it lost and
/// gained. For a failure report; nothing compares this text.
String snapshotDiff(ProfileSnapshot before, ProfileSnapshot after) {
  final out = StringBuffer();
  for (final name in after.changedFrom(before)) {
    final old = before.entries[name];
    final now = after.entries[name];
    out.writeln('${old == null ? '+' : (now == null ? '-' : '~')} $name');
    if (old is FileEntry && now is FileEntry) {
      for (final line in _lineDiff(before.text(name)!, after.text(name)!)) {
        out.writeln('    $line');
      }
    }
  }
  return '$out';
}

/// The projections [a] and [b] disagree on, as `name: a -> b`.
String projectionDiff(Map<String, String> a, Map<String, String> b) => [
  for (final name in ({...a.keys, ...b.keys}.toList()..sort()))
    if (a[name] != b[name])
      '$name: ${a[name] ?? 'absent'} -> '
          '${b[name] ?? 'absent'}',
].join('\n');

/// The lines between the common head and tail of [a] and [b]: those only
/// [a] has as `- `, those only [b] has as `+ `, at most 20 of them.
List<String> _lineDiff(String a, String b) {
  final left = const LineSplitter().convert(a);
  final right = const LineSplitter().convert(b);
  var head = 0;
  while (head < left.length &&
      head < right.length &&
      left[head] == right[head]) {
    head++;
  }
  var tail = 0;
  while (tail < left.length - head &&
      tail < right.length - head &&
      left[left.length - 1 - tail] == right[right.length - 1 - tail]) {
    tail++;
  }
  return [
    for (final line in left.sublist(head, left.length - tail)) '- $line',
    for (final line in right.sublist(head, right.length - tail)) '+ $line',
  ].take(20).toList();
}
