import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'relocation_notes.dart' show RecoveryRequired;

enum DirectoryEntryKind { directory, file }

/// One native object below a captured root, including hidden and empty entries.
final class DirectorySnapshotEntry {
  const DirectorySnapshotEntry._(
    this.path,
    this.kind,
    this.identity,
    this.sha256,
  );

  final String path;
  final DirectoryEntryKind kind;
  final String identity;
  final String? sha256;

  Map<String, Object?> _json() => {
    'path': path,
    'kind': kind.name,
    'identity': identity,
    if (kind == DirectoryEntryKind.file) 'sha256': sha256,
  };

  @override
  bool operator ==(Object other) =>
      other is DirectorySnapshotEntry &&
      path == other.path &&
      kind == other.kind &&
      identity == other.identity &&
      sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(path, kind, identity, sha256);
}

/// Exact recursive namespace and byte inventory for one directory move. The
/// caller owns the Documents domain while capturing and verifying snapshots.
/// Entries remain relative so the same objects can be verified after rename.
final class DirectorySnapshot {
  DirectorySnapshot._(this.identity, List<DirectorySnapshotEntry> entries)
    : entries = List.unmodifiable(entries) {
    _validate(identity, entries);
  }

  factory DirectorySnapshot.fromJson(
    Object? entries, {
    required String identity,
  }) {
    if (entries is! List) _refuse('Directory inventory must be a list.');
    final decoded = <DirectorySnapshotEntry>[];
    for (final entry in entries) {
      if (entry is! Map<String, Object?>)
        _refuse('Invalid directory inventory entry.');
      final kind = switch (entry['kind']) {
        'directory' => DirectoryEntryKind.directory,
        'file' => DirectoryEntryKind.file,
        _ => _refuse('Unsupported directory entry kind.'),
      };
      final keys = {
        'path',
        'kind',
        'identity',
        if (kind == DirectoryEntryKind.file) 'sha256',
      };
      if (entry.length != keys.length || !entry.keys.every(keys.contains)) {
        _refuse('Unsupported directory entry fields.');
      }
      decoded.add(
        DirectorySnapshotEntry._(
          _string(entry['path']),
          kind,
          _string(entry['identity']),
          kind == DirectoryEntryKind.file ? _string(entry['sha256']) : null,
        ),
      );
    }
    return DirectorySnapshot._(identity, decoded);
  }

  final String identity;
  final List<DirectorySnapshotEntry> entries;

  List<Map<String, Object?>> toJson() => [
    for (final entry in entries) entry._json(),
  ];

  static Future<DirectorySnapshot> capture(String path) async {
    try {
      if (!p.isAbsolute(path) ||
          p.normalize(path) != path ||
          path.contains('\u0000')) {
        _refuse('Directory snapshot root must be an absolute normalized path.');
      }
      final entries = <DirectorySnapshotEntry>[];
      final identity = await _captureDirectory(path, '', entries, {});
      entries.sort((a, b) => a.path.compareTo(b.path));
      return DirectorySnapshot._(identity, entries);
    } on RecoveryRequired {
      rethrow;
    } on Object catch (error) {
      throw RecoveryRequired('Cannot capture directory $path: $error');
    }
  }

  Future<void> verify(String path) async {
    final current = await capture(path);
    if (identity != current.identity || !_equal(entries, current.entries)) {
      _refuse('The recorded directory or its contents changed: $path.');
    }
  }
}

Future<String> _captureDirectory(
  String path,
  String relative,
  List<DirectorySnapshotEntry> entries,
  Set<String> identities,
) async {
  final before = await observeDirectory(path);
  final identity = before.identity;
  if (before.status != 0 || identity == null || !identities.add(identity)) {
    _refuse('Directory is missing, linked, repeated or unreadable: $path.');
  }
  if (relative.isNotEmpty) {
    entries.add(
      DirectorySnapshotEntry._(
        relative,
        DirectoryEntryKind.directory,
        identity,
        null,
      ),
    );
  }
  final children = await _listing(path);
  for (final (name, kind) in children) {
    final childPath = p.join(path, name);
    final childRelative = relative.isEmpty ? name : p.join(relative, name);
    if (kind == DirectoryEntryKind.directory) {
      await _captureDirectory(childPath, childRelative, entries, identities);
    } else {
      final observed = await observeFile(childPath);
      if (observed.status != 0 ||
          observed.identity == null ||
          observed.sha256Hex == null ||
          !identities.add(observed.identity!)) {
        _refuse('File is missing, linked, repeated or unreadable: $childPath.');
      }
      entries.add(
        DirectorySnapshotEntry._(
          childRelative,
          DirectoryEntryKind.file,
          observed.identity!,
          observed.sha256Hex!,
        ),
      );
    }
  }
  final after = await observeDirectory(path);
  if (after.status != 0 ||
      after.identity != identity ||
      !_equal(children, await _listing(path))) {
    _refuse('Directory changed during capture: $path.');
  }
  return identity;
}

Future<List<(String, DirectoryEntryKind)>> _listing(String path) async {
  final entries = <(String, DirectoryEntryKind)>[];
  await for (final entry in directoryEntries(
    Directory(path),
    followLinks: false,
  )) {
    final kind = switch (entry) {
      Directory() => DirectoryEntryKind.directory,
      File() => DirectoryEntryKind.file,
      _ => _refuse('Unsupported linked or special entry: ${entry.path}.'),
    };
    entries.add((p.basename(entry.path), kind));
  }
  entries.sort((a, b) => a.$1.compareTo(b.$1));
  return entries;
}

void _validate(String identity, List<DirectorySnapshotEntry> entries) {
  _identity(identity);
  final identities = {identity};
  final directories = <String>{};
  String? previous;
  for (final entry in entries) {
    final path = entry.path;
    if (path.isEmpty ||
        path == '.' ||
        path.contains('\u0000') ||
        p.isAbsolute(path) ||
        p.rootPrefix(path).isNotEmpty ||
        p.normalize(path) != path ||
        p.split(path).any((part) => part == '..' || part == '.') ||
        (previous != null && previous.compareTo(path) >= 0)) {
      _refuse('Directory entry paths must be sorted, unique and relative.');
    }
    final parent = p.dirname(path);
    if (parent != '.' && !directories.contains(parent)) {
      _refuse('Directory inventory omits a parent directory: $path.');
    }
    _identity(entry.identity);
    if (!identities.add(entry.identity))
      _refuse('Directory inventory repeats a native identity.');
    if (entry.kind == DirectoryEntryKind.directory) {
      directories.add(path);
    } else if (entry.sha256 == null ||
        _hash.stringMatch(entry.sha256!) != entry.sha256) {
      _refuse('Directory inventory contains an invalid file hash.');
    }
    previous = path;
  }
}

bool _equal<T>(List<T> a, List<T> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

String _string(Object? value) =>
    value is String ? value : _refuse('Invalid directory entry string.');
void _identity(String value) {
  if (value.isEmpty || value.contains('\u0000'))
    _refuse('Invalid directory native identity.');
}

final _hash = RegExp(r'^[0-9a-f]{64}$');
Never _refuse(String detail) => throw RecoveryRequired(detail);
