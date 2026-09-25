import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/bughouse/match.dart';
import '../chess/generation/tree_wire_v4_reader.dart';
import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import 'atomic_write.dart';
import 'bughouse_matches.dart';
import 'directory_entries.dart';
import 'integrity_report.dart';

/// These reads never enter a storage loader: match loading can rebuild BPGN.
/// The JSON checkpoint is authoritative; the export is compared, never repaired.
final class SavedArtifactChecks {
  SavedArtifactChecks(this.documents, {this.isCancelled});
  final Directory documents;
  final bool Function()? isCancelled;
  bool get cancelled => isCancelled?.call() ?? false;

  Future<List<IntegrityFinding>> generation() async {
    final findings = <IntegrityFinding>[];
    await _trees(documents, findings);
    return findings;
  }

  Future<void> _trees(
    Directory folder,
    List<IntegrityFinding> findings, {
    bool artifacts = false,
  }) async {
    if (cancelled) return;
    try {
      final observed = await observeDirectory(folder.path);
      if (observed.status == 1) return;
      if (observed.status != 0)
        throw const FormatException('The folder is linked or unreadable.');
      await for (final entry in directoryEntries(folder, followLinks: false)) {
        if (cancelled) return;
        final name = p.basename(entry.path);
        if (entry is Directory &&
            (!name.startsWith('.') || name == '.cap-generation')) {
          await _trees(
            entry,
            findings,
            artifacts: artifacts || name == '.cap-generation',
          );
        } else if (name == '.cap-generation') {
          findings.add(
            IntegrityFinding(
              IntegrityKind.unavailable,
              entry.path,
              'The generated artifact directory is not a regular directory.',
            ),
          );
        } else if (artifacts && name == 'tree.json') {
          findings.addAll(await _tree(entry.path));
        } else if (artifacts &&
            entry.path == temporaryPathFor(p.join(folder.path, 'tree.json'))) {
          findings.add(
            IntegrityFinding(
              IntegrityKind.unfinished,
              entry.path,
              'A staged generated tree remains; no repair was attempted.',
            ),
          );
        } else if (entry is Link && artifacts) {
          findings.add(
            IntegrityFinding(
              IntegrityKind.unavailable,
              entry.path,
              'A linked artifact path was not followed.',
            ),
          );
        }
      }
    } on Object {
      if (!artifacts) return;
      findings.add(
        IntegrityFinding(
          IntegrityKind.unavailable,
          folder.path,
          'Generated artifacts could not be checked: the folder is unavailable or linked.',
        ),
      );
    }
  }

  Future<List<IntegrityFinding>> _tree(String path) async {
    try {
      final observed = await observeFile(path);
      if (observed.status != 0 || observed.bytes == null)
        throw const FormatException('The tree is unreadable or linked.');
      final text = utf8.decode(observed.bytes!);
      final problem = text.length >= readOffThreadFrom
          ? await Isolate.run(() => _treeProblem(text))
          : _treeProblem(text);
      return problem == null
          ? []
          : [IntegrityFinding(problem.$1, path, problem.$2)];
    } on Object {
      return [
        IntegrityFinding(
          IntegrityKind.unavailable,
          path,
          'The generated tree could not be checked: it is unreadable or has an unsupported format.',
        ),
      ];
    }
  }

  Future<List<IntegrityFinding>> matches() async {
    final findings = <IntegrityFinding>[];
    if (cancelled) return findings;
    final root = Directory(p.join(documents.path, 'bughouse_matches'));
    try {
      final observed = await observeDirectory(root.path);
      if (observed.status == 1) return findings;
      if (observed.status != 0)
        throw const FormatException(
          'The match directory is linked or unreadable.',
        );
      await for (final entry in directoryEntries(root, followLinks: false)) {
        if (cancelled) return findings;
        if (p.basename(entry.path).startsWith('.')) continue;
        if (entry is Directory) {
          findings.addAll(await _match(entry.path));
        } else {
          findings.add(
            IntegrityFinding(
              IntegrityKind.unavailable,
              entry.path,
              'The match entry is not a regular directory.',
            ),
          );
        }
      }
    } on Object {
      findings.add(
        IntegrityFinding(
          IntegrityKind.unavailable,
          root.path,
          'Match exports could not be checked: the directory is unavailable or linked.',
        ),
      );
    }
    return findings;
  }

  Future<List<IntegrityFinding>> _matchStages(String folder) async {
    final findings = <IntegrityFinding>[];
    for (final name in ['match.json', 'games.bpgn']) {
      final stagePath = temporaryPathFor(p.join(folder, name));
      final stage = await observeFile(stagePath);
      if (stage.status == 1) continue;
      findings.add(
        IntegrityFinding(
          stage.status == 0
              ? IntegrityKind.unfinished
              : IntegrityKind.unavailable,
          stagePath,
          'An unverified match publication stage remains. No files were changed.',
        ),
      );
    }
    return findings;
  }

  Future<List<IntegrityFinding>> _match(String folder) async {
    final path = p.join(folder, 'match.json');
    try {
      if ((await observeDirectory(folder)).status != 0)
        throw const FormatException('The match folder changed.');
      final stages = await _matchStages(folder);
      if (stages.isNotEmpty) return stages;
      final json = await observeFile(path);
      if (json.status != 0 || json.bytes == null)
        throw const FormatException('The match checkpoint is unavailable.');
      final bytes = json.bytes!;
      final expected = await Isolate.run(
        () => matchBpgn(decodeMatchCheckpoint(utf8.decode(bytes))),
      );
      final exportPath = p.join(folder, 'games.bpgn');
      final export = await observeFile(exportPath);
      if (export.status == 1 && expected.isEmpty) return [];
      if (export.status == 1 ||
          (export.status == 0 && utf8.decode(export.bytes!) != expected)) {
        return [
          IntegrityFinding(
            IntegrityKind.derived,
            exportPath,
            'The BPGN export does not match its saved match checkpoint. No files were changed.',
          ),
        ];
      }
      if (export.status != 0)
        throw const FormatException('The BPGN export is unreadable or linked.');
      return [];
    } on Object {
      return [
        IntegrityFinding(
          IntegrityKind.unavailable,
          path,
          'The match could not be checked: its checkpoint or export is unavailable or has an unsupported format.',
        ),
      ];
    }
  }
}

(IntegrityKind, String)? _treeProblem(String text) =>
    switch (decodeTreeV4(text)) {
      TreeDecoded() => null,
      TreeUnsupported() => (
        IntegrityKind.unsupported,
        'The generated tree uses an unsupported format version.',
      ),
      TreeMalformed() => (
        IntegrityKind.unavailable,
        'The generated tree has malformed data.',
      ),
    };
