import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../diagnostics/log.dart';
import '../../storage/pending_writes.dart';
import '../../storage/master_games_import.dart';

/// A resumable series of weekly imports into the master games database at
/// [path]. Issues already in it are skipped, so a later run brings it up to
/// date; a stop finishes the current issue. Its HTTP client belongs to this
/// run only.
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

  /// The unreadable database this run set aside, if it had to.
  String? setAside;

  Future<void> start(int weeks) {
    if (running || _disposed) return Future.value();
    final work = _run(weeks.clamp(1, 520));
    pendingWrites?.watch(this, work);
    return work;
  }

  void stop() {
    if (!running) return;
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
    setAside = null;
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
      final database = await Isolate.run(() => masterGamesIssues(path));
      var kept = database.issues;
      setAside = database.setAside;
      String? firstCopy;
      for (
        var issue = latest;
        issue > latest - weeks && issue >= 920;
        issue--
      ) {
        if (_stopping) break;
        final newFile = kept.contains(issue)
            ? false
            : await _issue(client, issue, weeks);
        if (newFile == null) break;
        if (newFile && firstCopy != null) return _unreadableAgain(firstCopy);
        if (newFile) {
          firstCopy = setAside;
          // The new file holds only this issue: go through the whole
          // window again, the issues already done this run included.
          kept = {issue};
          issue = latest + 1;
          done = 0;
          continue;
        }
        done++;
        _notify();
      }
      status = _stopping
          ? 'Stopped. Download again to resume.'
          : 'TWIC database ready.';
      if (skipped > 0)
        status += ' Skipped $skipped unsupported or unfinished games.';
      if (setAside case final copy?)
        status +=
            ' The database could not be read, so it was set aside as '
            '${p.basename(copy)} and a new one started.';
    } on Object catch (error) {
      log.w('download TWIC', error);
      problem =
          'Could not finish the TWIC download. ${describeImportFailure(error)}';
      status = 'Completed issues are saved. Try again to resume.';
    } finally {
      client.close();
      running = false;
      _notify();
    }
  }

  /// Ends a run whose new file turned unreadable too: the disk is suspect,
  /// so both copies are kept and the run stops rather than start over again.
  void _unreadableAgain(String firstCopy) {
    final copies = '${p.basename(firstCopy)} and ${p.basename(setAside!)}';
    log.w('download TWIC', StateError('Unreadable again; set aside $copies.'));
    problem =
        'The master games database became unreadable again while '
        'downloading; it was set aside as $copies. '
        'Check the disk and try again.';
    status = 'Completed issues are saved. Try again to resume.';
  }

  /// Downloads and imports one issue: null when a stop arrived before the
  /// import began, otherwise whether the import found the database
  /// unreadable, set it aside and started a new one.
  Future<bool?> _issue(http.Client client, int issue, int weeks) async {
    status = 'Downloading TWIC $issue · ${done + 1} of $weeks';
    _notify();
    final response = await client
        .get(Uri.https('theweekinchess.com', '/zips/twic${issue}g.zip'))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200)
      throw StateError('TWIC $issue answered HTTP ${response.statusCode}.');
    if (_stopping) return null;
    status = 'Importing TWIC $issue · ${done + 1} of $weeks';
    _notify();
    final (path, bytes) = (this.path, response.bodyBytes);
    final (counts, copy) = await Isolate.run(() {
      String? copy;
      final counts = withMasterGames(
        path,
        (db) => importTwicIssueInto(db, issue, bytes),
        setAside: (value) => copy = value,
      );
      return (counts, copy);
    });
    setAside = copy ?? setAside;
    skipped += counts.$2;
    return copy != null;
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
