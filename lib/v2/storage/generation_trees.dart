import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/fen.dart';
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

typedef TreeLoader = Future<String?> Function(ChapterRef chapter, Fen root);

/// Search trees in the existing `.cap-generation` layout beside the chapter.
/// Failures are reported to the retained save obligation for exact retry.
/// Writing shares the document lock, so a folder move
/// cannot pass between checking the chapter and writing its tree.
final class GenerationTrees {
  GenerationTrees(this.recovery, {this.afterPublish});

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
        await afterPublish?.call();
      }),
    );
  }

  /// Most recent run for this exact board. Linked directories are never read.
  Future<String?> latest(ChapterRef chapter, Fen rootFen) => recovery.run(
    () async {
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
      if (await FileSystemEntity.type(folder, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return null;
      }
      await _ancestry(root.path, folder, create: false);
      final candidates = <({String path, DateTime modified})>[];
      await for (final entry in Directory(folder).list(followLinks: false)) {
        if (entry is! Directory || !p.basename(entry.path).startsWith('v2-')) {
          continue;
        }
        final file = p.join(entry.path, 'tree.json');
        if ((await observeFile(file)).status != 0) continue;
        candidates.add((
          path: file,
          modified: (await File(file).stat()).modified,
        ));
      }
      candidates.sort((a, b) => b.modified.compareTo(a.modified));
      for (final candidate in candidates) {
        final text = await recoveryText(candidate.path);
        if (text == null) continue;
        if (await _startsAt(text, rootFen.value)) return text;
      }
      return null;
    },
  );

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
