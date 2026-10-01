import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

/// Downloaded updates, under `updates/` in the app's cache folder.
///
/// Each download gets a private attempt folder, `<tag>-<random>/`, so a
/// half-written file, a second running copy of the app and an armed helper
/// never share a name. The file arrives as `<asset>.part`, is hashed as it
/// is written, and takes its real name only once its size and SHA-256 match
/// the release: a file under its real name is always a verified one. The
/// SHA-256 is worked out on another isolate, so hashing a large download
/// never holds up the window. A
/// download that fails or is cancelled takes its attempt folder with it, so
/// trying again is always a fresh start. Everything here is derived data:
/// the release can be downloaded again.
///
/// The helper that installs an update writes `last-error.txt` in the root
/// when it fails after the app has closed, naming the attempt folder's
/// `install.log`; the next start reads it once.

/// The file a release promises: what it is called, how big it is and what
/// its SHA-256 is (lower-case hex).
typedef ExpectedPayload = ({String tag, String name, int size, String sha256});

/// A downloaded file whose size and SHA-256 matched its release.
final class VerifiedPayload {
  const VerifiedPayload(this.path, this.sha256);

  final String path;
  final String sha256;

  /// The attempt folder, where the helper keeps its log.
  String get folder => p.dirname(path);
}

sealed class Received {
  const Received();
}

final class Verified extends Received {
  const Verified(this.payload);

  final VerifiedPayload payload;
}

enum Refusal { sizeMismatch, tooLarge, checksum }

/// The bytes were not the release's; they were deleted.
final class Refused extends Received {
  const Refused(this.refusal);

  final Refusal refusal;
}

final class ReceiveCancelled extends Received {
  const ReceiveCancelled();
}

/// The transfer broke off or the disk refused the file.
final class ReceiveFailed extends Received {
  const ReceiveFailed();
}

/// What the helper wrote when an install failed, and the folder holding
/// its `install.log`: the attempt folder it names, or the updates folder
/// when it names none there.
typedef FailedInstall = ({String report, String folder});

/// Written by the app to arm a helper; deleting it disarms the helper.
const armedName = 'install-requested';

/// Written by a helper once it runs, removed when it ends. A helper that
/// was killed leaves it behind, so it proves nothing on its own.
const helperReadyName = 'helper-ready';

/// Written by the app beside the armed marker when the user is updating
/// now: the helper opens the app again once it has installed. Without it
/// the app stays closed, as the user left it.
const reopenName = 'reopen';
const _failedInstallName = 'last-error.txt';

/// How recently a half-written download or an arming marker must have
/// changed for its folder to count as in use: a transfer stalls out long
/// before this, and a helper that takes longer than this to start never
/// will.
const _recentUse = Duration(minutes: 5);

/// The log path at the end of the helpers' failure report.
final _reportedLog = RegExp(r'Details: (.*install\.log)\s*$');

final class UpdateFolder {
  UpdateFolder(this.root);

  final Directory root;

  /// What the helper wrote when the last install failed, once: the file is
  /// removed as it is read, so the failure is reported at one start only.
  Future<FailedInstall?> takeFailedInstall() async {
    final file = File(p.join(root.path, _failedInstallName));
    try {
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      await file.delete();
      log.w('install the update', text);
      return (
        report: text.isEmpty ? 'The installer gave no reason.' : text,
        folder: await _logFolder(text),
      );
    } on Object catch (error) {
      log.w('read the last update error', error);
      return null;
    }
  }

  /// The attempt folder whose log [report] names, when it is one of ours
  /// and still there; else the updates folder.
  Future<String> _logFolder(String report) async {
    final named = _reportedLog.firstMatch(report)?[1];
    if (named != null) {
      final folder = p.dirname(named.trim());
      if (p.isWithin(root.path, folder) && await Directory(folder).exists()) {
        return folder;
      }
    }
    return root.path;
  }

  /// A file for [expected] that an earlier download verified and that still
  /// verifies, so a restart does not download it again.
  Future<VerifiedPayload?> verified(ExpectedPayload expected) async {
    try {
      if (!await root.exists()) return null;
      await for (final entry in root.list()) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('${expected.tag}-')) {
          continue;
        }
        final file = File(p.join(entry.path, expected.name));
        if (await file.exists() && await _matches(file, expected)) {
          return VerifiedPayload(file.path, expected.sha256);
        }
      }
    } on Object catch (error) {
      log.w('look for a downloaded update', error);
    }
    return null;
  }

  static Future<bool> _matches(File file, ExpectedPayload expected) async =>
      await file.length() == expected.size &&
      await _sha256Of(file.path) == expected.sha256;

  /// [path]'s SHA-256 in lower-case hex, worked out on another isolate.
  static Future<String> _sha256Of(String path) => Isolate.run(
    () async => '${await sha256.bind(File(path).openRead()).first}',
  );

  /// Writes [bytes] as [expected]'s file and keeps it only if it is exactly
  /// the release's. [announced] is the length the server gave; [stop]
  /// completing cancels the transfer at once, even while bytes are stalled.
  Future<Received> receive(
    ExpectedPayload expected,
    Stream<List<int>> bytes, {
    int? announced,
    required void Function(int received) progress,
    required Future<void> stop,
  }) async {
    if (announced != null && announced != expected.size) {
      unawaited(bytes.listen(null).cancel());
      return const Refused(Refusal.sizeMismatch);
    }
    Directory? attempt;
    try {
      await root.create(recursive: true);
      attempt = await root.createTemp('${expected.tag}-');
      final part = File(p.join(attempt.path, '${expected.name}.part'));
      final outcome = await _write(part, expected, bytes, progress, stop);
      if (outcome != null) {
        await _discard(attempt);
        return outcome;
      }
      final named = await part.rename(p.join(attempt.path, expected.name));
      return Verified(VerifiedPayload(named.path, expected.sha256));
    } on Object catch (error) {
      log.w('save the update download', error);
      if (attempt != null) await _discard(attempt);
      return const ReceiveFailed();
    }
  }

  /// Streams [bytes] into [part], then hashes it; null when the file is
  /// complete and matches, else why it is not kept.
  static Future<Received?> _write(
    File part,
    ExpectedPayload expected,
    Stream<List<int>> bytes,
    void Function(int received) progress,
    Future<void> stop,
  ) async {
    final sink = part.openWrite();
    final done = Completer<Received?>();
    var received = 0;
    late final StreamSubscription<List<int>> subscription;
    void end(Received? outcome) {
      if (done.isCompleted) return;
      unawaited(subscription.cancel());
      done.complete(outcome);
    }

    subscription = bytes.listen(
      (chunk) {
        received += chunk.length;
        if (received > expected.size) {
          return end(const Refused(Refusal.tooLarge));
        }
        sink.add(chunk);
        progress(received);
      },
      onError: (Object error) {
        log.w('download the update', error);
        end(const ReceiveFailed());
      },
      onDone: () => end(null),
      cancelOnError: true,
    );
    unawaited(stop.then((_) => end(const ReceiveCancelled())));
    final outcome = await done.future;
    await sink.close();
    if (outcome != null) return outcome;
    if (received != expected.size) return const Refused(Refusal.sizeMismatch);
    return await _sha256Of(part.path) == expected.sha256
        ? null
        : const Refused(Refusal.checksum);
  }

  /// Removes every attempt folder but [keep]'s that nothing uses any more:
  /// older versions' files are not wanted again. A folder stays while
  /// another running copy is writing its download or arming its helper,
  /// and while its helper waits for the app to close — [helperRunning]
  /// says whether any helper does, since a killed one leaves its ready file
  /// behind.
  Future<void> prune({
    required VerifiedPayload keep,
    required bool helperRunning,
  }) async {
    try {
      final now = DateTime.now();
      await for (final entry in root.list()) {
        if (entry is! Directory || p.equals(entry.path, keep.folder)) continue;
        if (await _inUse(entry, now, helperRunning: helperRunning)) continue;
        await _discard(entry);
      }
    } on Object catch (error) {
      log.w('remove old update downloads', error);
    }
  }

  static Future<bool> _inUse(
    Directory attempt,
    DateTime now, {
    required bool helperRunning,
  }) async {
    await for (final entry in attempt.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (name == helperReadyName && helperRunning) return true;
      final marker = name == armedName || name.endsWith('.part');
      if (marker && now.difference(await entry.lastModified()) < _recentUse) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _discard(Directory attempt) async {
    try {
      await attempt.delete(recursive: true);
    } on Object catch (error) {
      log.w('remove an update download', error);
    }
  }
}
