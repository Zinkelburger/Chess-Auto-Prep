import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

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

/// Search trees in the existing `.cap-generation` layout beside the chapter.
/// They are derived data: a tree that cannot be kept — the chapter was moved
/// or deleted meanwhile, the disk is full — is logged and skipped, and never
/// stops the next search. Writing shares the document lock, so a folder move
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
          log.i('search tree not kept: $source is gone');
          return;
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

  /// A tree already written for this run is left as it is. Whatever a crash
  /// left at the staging name is removed first — unlinked, never followed.
  Future<void> _publish(String path, List<int> bytes) async {
    if ((await observeFile(path)).status != 1) return;
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
