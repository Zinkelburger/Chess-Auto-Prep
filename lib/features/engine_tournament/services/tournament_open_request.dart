/// Cross-process hand-off: "open the app on this tournament".
///
/// A file, not a socket or a URL scheme, for the same reason the opponent
/// list is a file: it works whether or not the app is running. An agent that
/// starts a match through the MCP tools while the app is closed leaves the
/// request behind, and the next launch honours it; if the app *is* running it
/// sees the file appear and jumps there immediately.
///
/// Pure `dart:io`, so the MCP side and the app agree on one format with no
/// Flutter in the middle.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String kOpenRequestFileName = 'open_request.json';

/// How long a request stays worth honouring.
///
/// Without a cutoff, a request written days ago would hijack an unrelated
/// launch — the user opens the app to look at their repertoire and lands on a
/// match they have forgotten about.
const Duration kOpenRequestMaxAge = Duration(hours: 24);

class TournamentOpenRequest {
  const TournamentOpenRequest({
    required this.tournamentId,
    required this.requestedAt,
  });

  /// Directory name of the tournament to select.
  final String tournamentId;

  final DateTime requestedAt;

  bool isFreshAt(DateTime now, {Duration maxAge = kOpenRequestMaxAge}) {
    final age = now.difference(requestedAt);
    // A negative age means the clock moved between writing and reading. The
    // writer and the reader are the same machine, so that is skew, not a
    // reason to drop the request.
    return age.isNegative || age <= maxAge;
  }

  Map<String, dynamic> toJson() => {
    'tournamentId': tournamentId,
    'requestedAt': requestedAt.toIso8601String(),
  };

  static TournamentOpenRequest? fromJson(Map<String, dynamic> json) {
    final id = (json['tournamentId'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    return TournamentOpenRequest(
      tournamentId: id,
      requestedAt:
          DateTime.tryParse(json['requestedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Reads and writes [kOpenRequestFileName] in the tournaments directory.
class TournamentOpenRequests {
  TournamentOpenRequests(this.directory);

  /// `Documents/engine_tournaments`.
  final Directory directory;

  File get file => File(p.join(directory.path, kOpenRequestFileName));

  Future<void> write(String tournamentId) async {
    await directory.create(recursive: true);
    final payload = jsonEncode(
      TournamentOpenRequest(
        tournamentId: tournamentId,
        requestedAt: DateTime.now(),
      ).toJson(),
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(file.path);
  }

  /// Read the pending request and clear it in the same step.
  ///
  /// Reading and clearing are inseparable on purpose: a request left in place
  /// would re-fire on every mode switch for the rest of the session.
  Future<TournamentOpenRequest?> take({DateTime? now}) async {
    if (!await file.exists()) return null;
    TournamentOpenRequest? request;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map) {
        request = TournamentOpenRequest.fromJson(
          Map<String, dynamic>.from(json),
        );
      }
    } catch (_) {
      // A half-written or malformed request is dropped, not retried.
    }
    try {
      await file.delete();
    } catch (_) {
      /* already gone */
    }
    if (request == null) return null;
    return request.isFreshAt(now ?? DateTime.now()) ? request : null;
  }
}
