/// The one thing a relocation cannot do in a single step.
///
/// Moving a chapter is a rename on disk; the training rows that name it are a
/// rewrite of four other files. A machine that stops between them would leave
/// the rows pointing at a name nothing answers to, and the user's schedule,
/// streaks and answers for that chapter would look like another chapter's.
///
/// So the pair is written down before the rename and taken away after the
/// rows are rewritten. Whichever relocation comes next finishes what the note
/// says before starting its own. The note lives in Support, next to the kept
/// versions: it is this app's bookkeeping, not something to appear in a
/// folder the user syncs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';

/// A move that has happened on disk and whose training rows may not have been
/// rewritten yet.
typedef UnfinishedMove = ({String from, String to});

final class PendingRepoints {
  const PendingRepoints(this.support);

  /// The Support folder itself; the note is one file directly in it.
  final Directory support;

  File get _file => File(p.join(support.path, _name));

  /// Writes down that [from] is about to become [to]. Throws, like the rest
  /// of a mutation's preparation, when it cannot be written: a move whose
  /// second half could be lost without trace does not start.
  Future<void> record(String from, String to) async {
    await support.create(recursive: true);
    await replaceFile(
      _file.path,
      utf8.encode(jsonEncode({'from': from, 'to': to})),
    );
  }

  /// Takes the note away, the rows now naming what they should.
  Future<void> clear() async {
    try {
      if (await _file.exists()) await _file.delete();
    } on FileSystemException catch (error) {
      log.w('take away the note at ${_file.path}', error);
    }
  }

  /// The move whose training rows are still owed, or null when none is.
  Future<UnfinishedMove?> read() async {
    try {
      if (!await _file.exists()) return null;
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map<String, Object?>) return null;
      final from = json['from'];
      final to = json['to'];
      if (from is! String || to is! String) return null;
      return (from: from, to: to);
    } on Object catch (error) {
      log.w('read the note at ${_file.path}', error);
      return null;
    }
  }
}

const _name = 'unfinished-move.json';
