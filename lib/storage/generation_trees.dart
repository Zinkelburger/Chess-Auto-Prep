import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'chapter_files.dart';
import 'file_lock.dart';
import 'recovery_files.dart';
import 'recovery_gate.dart';

/// The exact tree of one accepted search. The caller freezes [runId] and text
/// once; a retry never selects another run directory or overwrites another tree.
typedef TreeKeeper =
    Future<void> Function(
      ChapterRef chapter,
      String tree, {
      required String runId,
    });

/// The saved trees for [chapter] that start at [root], newest first, each
/// read only when asked for.
typedef TreeLoader = Stream<String> Function(ChapterRef chapter, Fen root);

/// Search trees in the existing `.cap-generation` layout beside the chapter.
/// Failures are reported to the retained save obligation for exact retry.
/// Writing shares the document lock, so a folder move
/// cannot pass between checking the chapter and writing its tree.
final class GenerationTrees {
  GenerationTrees(this.recovery, {this.afterPublish});

  /// How many earlier runs of a chapter are kept beside the one just written;
  /// following the board writes a tree at every step.
  static const keptRuns = 8;

  final RecoveryGate recovery;

  /// Fault seam after native publication, before its acknowledgement.
  final Future<void> Function()? afterPublish;

  Future<void> keep(ChapterRef chapter, String tree, {required String runId}) {
    final configured = p.normalize(recovery.documents.absolute.path);
    final path = chapter.path;
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').hasMatch(runId) ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path.contains('\u0000') ||
        !p.isWithin(configured, path)) {
      return Future.error(
        const FileSystemException('Invalid generation destination.'),
      );
    }
    final bytes = utf8.encode(tree);
    final root = recovery.training.documents;
    final source = p.join(root.path, p.relative(path, from: configured));
    final folder = p.join(
      p.dirname(source),
      '.cap-generation',
      p.basename(source),
      'v2-$runId',
    );
    return recovery.run(
      () => withDirectoryLock(root, () async {
        if (canonicalRecoveryRoot(recovery.documents).path != root.path) {
          throw const FileSystemException('The Documents directory changed.');
        }
        await _ancestry(root.path, p.dirname(source), create: false);
        if ((await observeFile(source)).status != 0) {
          throw const FileSystemException(
            'The source chapter is no longer available.',
          );
        }
        await _ancestry(root.path, folder, create: true);
        if (canonicalRecoveryRoot(recovery.documents).path != root.path) {
          throw const FileSystemException('The Documents directory changed.');
        }
        await _publish(p.join(folder, 'tree.json'), bytes);
        await flushRecoveryAncestry(folder, through: root.path);
        await _prune(p.dirname(folder), keep: folder);
        await afterPublish?.call();
      }),
    );
  }

  /// The runs for this exact board, newest first. Each is read, under the
  /// recovery gate, only when the one before it was not wanted; one that
  /// cannot be read is logged and passed over, and when none could be read
  /// the stream ends in an error rather than reading as no saved search.
  /// Linked directories are never read.
  Stream<String> startingAt(ChapterRef chapter, Fen rootFen) async* {
    final configured = p.normalize(recovery.documents.absolute.path);
    if (!p.isAbsolute(chapter.path) ||
        p.normalize(chapter.path) != chapter.path ||
        !p.isWithin(configured, chapter.path)) {
      throw const FileSystemException('Invalid saved search location.');
    }
    final root = recovery.training.documents;
    final source = p.join(
      root.path,
      p.relative(chapter.path, from: configured),
    );
    final folder = p.join(
      p.dirname(source),
      '.cap-generation',
      p.basename(source),
    );
    final runs = await recovery.run(() async {
      if (await FileSystemEntity.type(folder, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return const <String>[];
      }
      await _ancestry(root.path, folder, create: false);
      return [for (final run in await _runs(folder)) run.path];
    });
    var failed = false;
    var read = false;
    for (final run in runs) {
      final String? text;
      try {
        text = await recovery.run(() async {
          await _ancestry(root.path, run, create: false);
          // Gone, linked, or still linked at its staging name by a
          // publication a crash cut short: not a saved search yet.
          final observed = await observeFile(p.join(run, 'tree.json'));
          if (observed.status != 0 || observed.bytes == null) return null;
          final text = exactText(observed.bytes!);
          return await _startsAt(text, rootFen.value) ? text : null;
        });
      } on Object catch (error) {
        log.w('read saved search $run', error);
        failed = true;
        continue;
      }
      read = true;
      if (text != null) yield text;
    }
    if (failed && !read) {
      throw const FileSystemException('No saved search could be read.');
    }
  }

  /// The v2 runs in [folder], newest first: real directories holding a
  /// tree, never followed through a link.
  Future<List<({String path, DateTime modified})>> _runs(String folder) async {
    final runs = <({String path, DateTime modified})>[];
    await for (final entry in Directory(folder).list(followLinks: false)) {
      if (entry is! Directory || !p.basename(entry.path).startsWith('v2-')) {
        continue;
      }
      final file = p.join(entry.path, 'tree.json');
      if (await FileSystemEntity.type(file, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      runs.add((path: entry.path, modified: await File(file).lastModified()));
    }
    runs.sort((a, b) => b.modified.compareTo(a.modified));
    return runs;
  }

  /// Removes all but the newest [keptRuns] v2 runs in [folder] besides
  /// [keep]. Derived data: a run that cannot be removed is logged and left.
  /// Anything that is not the app's own v2 run, such as a v1 tree or an
  /// agent's `v2-agent-` run, is never touched. Runs are counted per chapter,
  /// not per root: following the board starts a new root at every step.
  Future<void> _prune(String folder, {required String keep}) async {
    try {
      final others = [
        for (final run in await _runs(folder))
          if (run.path != keep && !p.basename(run.path).startsWith('v2-agent-'))
            run.path,
      ];
      for (final run in others.skip(keptRuns)) {
        try {
          await Directory(run).delete(recursive: true);
        } on Object catch (error) {
          log.w('remove old saved search $run', error);
        }
      }
    } on Object catch (error) {
      log.w('remove old saved searches', error);
    }
  }

  /// A tree already written for this run is left as it is. Whatever a crash
  /// left at the staging name is removed first — unlinked, never followed.
  Future<void> _publish(String path, List<int> bytes) async {
    final observed = await observeFile(path);
    if (observed.status == 0) {
      if (await recoveryText(path) != utf8.decode(bytes)) {
        throw const FileSystemException(
          'A different tree already occupies this run.',
        );
      }
      return;
    }
    if (observed.status != 1) {
      throw const FileSystemException('The saved tree cannot be verified.');
    }
    final stage = temporaryPathFor(path);
    if (await FileSystemEntity.type(stage, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await File(stage).delete();
    }
    await createFileExclusively(path, bytes);
  }

  Future<void> _ancestry(
    String root,
    String folder, {
    required bool create,
  }) async {
    var path = root;
    for (final part in p.split(p.relative(folder, from: root))) {
      if (part == '.') continue;
      path = p.join(path, part);
      final observed = await observeDirectory(path);
      if (observed.status == 1 && create) {
        await Directory(path).create();
        await flushRecoveryDirectory(p.dirname(path));
      } else if (observed.status != 0) {
        throw FileSystemException(
          'Generation ancestry is unavailable or linked.',
          path,
        );
      }
    }
  }
}

Future<bool> _startsAt(String text, String fen) => Isolate.run(() {
  try {
    final json = jsonDecode(text);
    return json is Map &&
        json['tree'] is Map &&
        (json['tree'] as Map)['fen'] == fen;
  } on FormatException {
    return false;
  }
});
