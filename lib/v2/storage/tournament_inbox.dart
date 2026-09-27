import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'recovery_files.dart';

abstract interface class TournamentNotifications {
  Stream<void> changes();
  Future<String?> takeRequest();
}

/// Watches the root and each direct run folder, including on Linux where a
/// recursive Directory.watch is unavailable. Each listener owns its handles.
final class TournamentInbox implements TournamentNotifications {
  const TournamentInbox(this.root, {this.afterClaim});
  final Future<void> Function()? afterClaim;
  final Directory root;

  @override
  Stream<void> changes() => _DirectoryWatch(root).events.stream;

  @override
  Future<String?> takeRequest() async {
    final source = p.join(root.path, 'open_request.json');
    if (await FileSystemEntity.type(source, followLinks: false) ==
        FileSystemEntityType.notFound)
      return null;
    // Atomic namespace claim: a writer may replace the public name at any
    // instant. Only this private, claimed request is read and removed.
    final claimed = File(
      p.join(
        root.path,
        '.open-request-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await movePathNoReplace(source, claimed.path);
    } on FileSystemException catch (error) {
      if (error is PathNotFoundException ||
          error.osError?.errorCode == 2 ||
          (Platform.isWindows && error.osError?.errorCode == 3))
        return null;
      rethrow;
    }
    try {
      await afterClaim?.call();
      final text = await recoveryText(claimed.path);
      final data = jsonDecode(text ?? '');
      if (data is! Map<String, Object?>) return null;
      final id = data['tournamentId'];
      final when = data['requestedAt'];
      final date = when is String ? DateTime.tryParse(when) : null;
      if (id is! String ||
          id.isEmpty ||
          id.startsWith('.') ||
          id.contains(RegExp(r'[\\/\x00-\x1f]')) ||
          date == null)
        return null;
      if (DateTime.now().difference(date) > const Duration(hours: 24))
        return null;
      return id;
    } on FormatException {
      log.w('open tournament request', 'Unreadable request ignored.');
      return null;
    } finally {
      await claimed.delete();
    }
  }
}

final class _DirectoryWatch {
  _DirectoryWatch(this.root);
  final Directory root;
  final _watches = <String, StreamSubscription<FileSystemEvent>>{};
  bool _closed = false;
  Future<void> _syncing = Future.value();
  late final events = StreamController<void>(
    onListen: _refresh,
    onCancel: _close,
  );

  void _refresh() {
    _syncing = _syncing.then((_) => _reconcile()).catchError(_failed);
  }

  Future<void> _reconcile() async {
    if (_closed) return;
    await recoveryDirectory(root, create: true);
    _attach(root.path);
    final folders = <String>{root.path};
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory && !p.basename(entry.path).startsWith('.'))
        folders.add(entry.path);
    }
    for (final path in _watches.keys.toList()) {
      if (!folders.contains(path)) await _watches.remove(path)!.cancel();
    }
    for (final path in folders) {
      _attach(path);
    }
    if (!_closed) events.add(null);
  }

  void _attach(String path) {
    if (_closed || _watches.containsKey(path)) return;
    _watches[path] = Directory(path).watch().listen((event) {
      if (p.basename(event.path).startsWith('.')) return;
      if (event.isDirectory && path == root.path) _refresh();
      if (!_closed) events.add(null);
    }, onError: _failed);
  }

  void _failed(Object error) {
    if (!_closed) events.addError(error);
  }

  Future<void> _close() async {
    _closed = true;
    await _syncing;
    await Future.wait(_watches.values.map((s) => s.cancel()));
    unawaited(events.close());
  }
}
