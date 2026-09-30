import 'dart:async';

import 'package:http/http.dart' as http;

import '../diagnostics/log.dart';

/// The one way to the free position services the user opts into (ChessDB,
/// the Lichess cloud), owned by the environment for the life of the app:
/// one request at a time across every run that asks, and a short wait for
/// each. A run takes its share with [run], which keeps that run's manners.
///
/// The HTTP client is the environment's; this never closes it.
final class RemoteQueue {
  RemoteQueue(http.Client client) : _client = client;

  /// A queue with no network behind it: every request is unreachable, as
  /// in a test that never set one up.
  RemoteQueue.none() : _client = null;

  final http.Client? _client;
  Future<void> _tail = Future.value();

  /// How long one request may take before it counts as not answered.
  static const wait = Duration(seconds: 3);

  /// A run's share of the queue, allowed [limit] requests.
  RemoteRun run({int limit = 1000}) => RemoteRun._(this, limit);

  /// [uri] asked in turn after every request asked for before it, from any
  /// run. A request not answered in [wait] is aborted and counts as not
  /// answered, but the next request waits until this one has actually
  /// settled, so two are never out at once, least of all when the service
  /// is slow. Null, and nothing sent, when [stillWanted] says no once its
  /// turn comes, so a run that stopped asking frees the queue at once.
  Future<http.Response?> _get(Uri uri, {bool Function()? stillWanted}) async {
    final before = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    var handedOff = false;
    try {
      await before;
      if (stillWanted != null && !stillWanted()) return null;
      final client = _client;
      if (client == null) throw StateError('no network in this environment');
      final abort = Completer<void>();
      final timer = Timer(wait, abort.complete);
      final request = _send(
        client,
        http.AbortableRequest('GET', uri, abortTrigger: abort.future),
      );
      handedOff = true;
      unawaited(
        request.then<void>((_) {}, onError: (_) {}).whenComplete(() {
          timer.cancel();
          gate.complete();
        }),
      );
      return await request.timeout(wait);
    } finally {
      if (!handedOff) gate.complete();
    }
  }

  static Future<http.Response> _send(
    http.Client client,
    http.BaseRequest request,
  ) async => http.Response.fromStream(await client.send(request));
}

/// One run's lookups through the [RemoteQueue]: at most [limit] requests,
/// and none after the service has refused (429), failed (5xx) or missed
/// [missesToDrop] requests in a row, so a run does not keep knocking.
///
/// A run the service dropped is [dropped]: what it found is incomplete,
/// and whoever shows the result says so rather than calling it finished.
final class RemoteRun {
  RemoteRun._(this._queue, this.limit);

  final RemoteQueue _queue;
  final int limit;

  /// How many requests in a row may go unanswered — a timeout, no network —
  /// before the run stops asking. One slow answer is not an outage.
  static const missesToDrop = 3;

  int _requests = 0;
  int _misses = 0;
  bool _dropped = false;
  bool _closed = false;

  /// Whether the service stopped answering this run.
  bool get dropped => _dropped;

  /// Whether the run used every request it was allowed.
  bool get spent => _requests >= limit;

  /// The body of a 200 answer to [uri]; null for any other answer, or when
  /// the run may no longer ask.
  Future<String?> get(Uri uri) async {
    if (_closed || _dropped || spent) return null;
    _requests++;
    try {
      final response = await _queue._get(
        uri,
        stillWanted: () => !_closed && !_dropped,
      );
      if (response == null) return null;
      _misses = 0;
      if (response.statusCode == 429 || response.statusCode >= 500) {
        _drop(uri, 'HTTP ${response.statusCode}');
      }
      return response.statusCode == 200 ? response.body : null;
    } on Object catch (error) {
      log.w('ask ${uri.host}', error);
      if (++_misses >= missesToDrop) _drop(uri, '$missesToDrop misses');
      return null;
    }
  }

  void _drop(Uri uri, String why) {
    if (_closed || _dropped) return;
    _dropped = true;
    log.w('ask ${uri.host}', '$why; no more asked this run');
  }

  /// No request is made after this, including those already waiting in
  /// the queue; one in flight comes back as it will.
  void close() => _closed = true;
}
