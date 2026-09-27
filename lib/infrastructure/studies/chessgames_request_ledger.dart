/// The app-wide request budget for chessgames.com, persisted across runs.
///
/// Per-run pacing alone got the user's IP banned: restarting an import, or
/// running several back to back, reset the pace and fired straight away, and a
/// ban page was retried as if it were a transient throttle. This ledger is the
/// one place every chessgames.com request is admitted, whichever dialog or
/// background run makes it:
///
///   * at least [minGap] between any two requests, even across runs;
///   * at most [dailyLimit] requests in any rolling [window];
///   * after a ban page, no requests at all for [banCooldown].
library;

import 'dart:convert';
import 'dart:io';

import '../../utils/atomic_file.dart';

class ChessgamesRequestLedger {
  ChessgamesRequestLedger(this._file, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const Duration minGap = Duration(seconds: 20);
  static const int dailyLimit = 150;
  static const Duration window = Duration(hours: 24);
  static const Duration banCooldown = Duration(hours: 24);

  final Future<File> Function() _file;
  final DateTime Function() _clock;
  Future<void> _tail = Future.value();

  /// Reserve one request.
  ///
  /// Returns [Duration.zero] when the request is recorded and may go out now;
  /// otherwise how long until one may, recording nothing.
  Future<Duration> reserve() => _locked(() async {
    final now = _clock();
    final state = await _read(now);
    final at = state.nextAllowed;
    if (at != null && at.isAfter(now)) return at.difference(now);
    state.requests.add(now);
    await _write(state);
    return Duration.zero;
  });

  /// The server served a ban page: stop every request for [banCooldown].
  Future<void> recordBan() => _locked(() async {
    final now = _clock();
    final state = await _read(now);
    state.bannedUntil = now.add(banCooldown);
    await _write(state);
  });

  Future<T> _locked<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<_LedgerState> _read(DateTime now) async {
    final state = _LedgerState();
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      if (json is! Map) return state;
      final banned = json['banned_until'];
      if (banned is int) {
        final until = DateTime.fromMillisecondsSinceEpoch(banned);
        if (until.isAfter(now)) state.bannedUntil = until;
      }
      final cutoff = now.subtract(window);
      for (final ms in (json['requests'] as List? ?? const [])) {
        if (ms is! int) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(ms);
        if (at.isAfter(cutoff)) state.requests.add(at);
      }
      state.requests.sort();
    } on FileSystemException {
      // No ledger yet.
    } on FormatException {
      // Unreadable ledger: start a fresh one rather than block forever.
    }
    return state;
  }

  Future<void> _write(_LedgerState state) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await writeTextFileAtomically(
      file,
      jsonEncode({
        'banned_until': state.bannedUntil?.millisecondsSinceEpoch,
        'requests': [
          for (final at in state.requests) at.millisecondsSinceEpoch,
        ],
      }),
    );
  }
}

class _LedgerState {
  final List<DateTime> requests = [];
  DateTime? bannedUntil;

  DateTime? get nextAllowed {
    DateTime? latest = bannedUntil;
    void atLeast(DateTime t) {
      if (latest == null || t.isAfter(latest!)) latest = t;
    }

    if (requests.isNotEmpty) {
      atLeast(requests.last.add(ChessgamesRequestLedger.minGap));
    }
    if (requests.length >= ChessgamesRequestLedger.dailyLimit) {
      atLeast(
        requests[requests.length - ChessgamesRequestLedger.dailyLimit].add(
          ChessgamesRequestLedger.window,
        ),
      );
    }
    return latest;
  }
}
