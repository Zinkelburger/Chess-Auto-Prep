import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;

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

/// Immutable artifacts in the existing `.cap-generation` layout. Publication
/// shares the document recovery domain, so a supported folder move cannot pass
/// between checking managed ancestry and publishing its derived tree.
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
          throw FileSystemException(
            'The source chapter is unavailable.',
            source,
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

  Future<void> _publish(String path, List<int> bytes) async {
    final current = await observeFile(path);
    if (current.status == 0 && !listEquals(current.bytes, bytes)) {
      throw FileSystemException(
        'A different search tree already occupies this run.',
        path,
      );
    }
    if (current.status != 0 && current.status != 1) {
      throw FileSystemException(
        'The search tree is unreadable or unsupported.',
        path,
      );
    }
    // A crash may leave our complete stage. Only the exact frozen bytes are
    // disposable; unknown or linked staging material is preserved and refused.
    final stagePath = temporaryPathFor(path);
    final stage = await observeFile(stagePath);
    if (stage.status == 0 && listEquals(stage.bytes, bytes)) {
      await File(stagePath).delete();
    } else {
      await discardLeftoverStage(path);
    }
    if (current.status == 1) await createFileExclusively(path, bytes);
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
