import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../diagnostics/log.dart';
import '../../storage/pending_writes.dart';
import '../../storage/twic_import.dart';

/// A resumable series of weekly imports. A stop finishes the current issue;
/// retry skips committed issues. Its HTTP client belongs to this run only.
class TwicDownload extends ChangeNotifier {
  TwicDownload(this.path, {http.Client Function()? client, this.pendingWrites})
    : _client = client ?? http.Client.new;

  final String path;
  final http.Client Function() _client;
  final PendingWrites? pendingWrites;
  bool running = false;
  bool _stopping = false;
  bool _disposed = false;
  String status = '';
  String? problem;
  int done = 0;
  int total = 0;
  int skipped = 0;

  Future<void> start(int weeks) {
    if (running || _disposed) return Future.value();
    final work = _run(weeks.clamp(1, 520));
    pendingWrites?.watch(this, work);
    return work;
  }

  void stop() {
    _stopping = true;
    status = 'Stopping after the current issue…';
    _notify();
  }

  Future<void> _run(int weeks) async {
    running = true;
    _stopping = false;
    problem = null;
    done = 0;
    total = weeks;
    skipped = 0;
    status = 'Finding the latest TWIC issue…';
    _notify();
    final client = _client();
    try {
      final index = await client
          .get(Uri.https('theweekinchess.com', '/twic'))
          .timeout(const Duration(seconds: 30));
      if (index.statusCode != 200)
        throw StateError('TWIC answered HTTP ${index.statusCode}.');
      final issues =
          RegExp(r'twic(\d+)g\.zip')
              .allMatches(index.body)
              .map((match) => int.parse(match[1]!))
              .toList()
            ..sort();
      if (issues.isEmpty)
        throw const FormatException('Could not find TWIC downloads.');
      final latest = issues.last;
      final path = this.path;
      final kept = await Isolate.run(() => downloadedTwicIssues(path));
      for (
        var issue = latest;
        issue > latest - weeks && issue >= 920;
        issue--
      ) {
        if (_stopping) break;
        if (!kept.contains(issue)) {
          status = 'Downloading TWIC $issue · ${done + 1} of $weeks';
          _notify();
          final response = await client
              .get(Uri.https('theweekinchess.com', '/zips/twic${issue}g.zip'))
              .timeout(const Duration(seconds: 60));
          if (response.statusCode != 200)
            throw StateError(
              'TWIC $issue answered HTTP ${response.statusCode}.',
            );
          if (_stopping) break;
          status = 'Importing TWIC $issue · ${done + 1} of $weeks';
          _notify();
          final bytes = response.bodyBytes;
          final result = await Isolate.run(
            () => importTwicIssue(path, issue, bytes),
          );
          skipped += result.$2;
        }
        done++;
        _notify();
      }
      status = _stopping
          ? 'Stopped. Download again to resume.'
          : 'TWIC database ready.';
      if (skipped > 0)
        status += ' Skipped $skipped unsupported or unfinished games.';
    } on Object catch (error) {
      log.w('download TWIC', error);
      problem = 'Could not finish the TWIC download. $error';
      status = 'Completed issues are saved. Try again to resume.';
    } finally {
      client.close();
      running = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopping = true;
    super.dispose();
  }
}
