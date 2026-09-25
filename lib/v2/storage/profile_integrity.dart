import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'book_integrity.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'foreign_recovery.dart';
import 'integrity_report.dart';
import 'mutation_guards.dart';
import 'recovery_files.dart';
import 'recovery_gate.dart';
import 'saved_artifact_checks.dart';
import 'settings.dart';

/// A diagnostic reader, never a recovery entrypoint. Only temporary lock
/// databases may change: no profile directory is created, repaired or removed.
final class ProfileIntegrity implements IntegrityReader {
  ProfileIntegrity({required this.documents, required this.support});
  final Directory documents;
  final Directory support;

  @override
  Future<IntegrityReport> read() async {
    final findings = <IntegrityFinding>[];
    final checked = <String>[];
    final skipped = <String>[];
    try {
      final root = canonicalRecoveryRoot(documents);
      final metadata = canonicalRecoveryRoot(support);
      final domain = Directory(
        p.join(root.path, 'repertoires', '.cap-directory-domain'),
      );
      final domainPath = canonicalRecoveryRoot(domain).path;
      // The normal nested helper always acquires Documents. Refuse these
      // malformed boundaries before the outer acquisition can self-block.
      if (domainPath == root.path || domainPath == metadata.path) {
        throw const FileSystemException('Profile lock boundaries overlap.');
      }
      await withDirectoryLock(
        domain,
        () => lockedForRelocation(
          root,
          DocumentRef(root.path),
          [metadata],
          () async {
            await _bound(root, metadata);
            findings.addAll(await _settings(metadata));
            checked.add('Settings file format (credentials are not checked)');
            final ready = await _protocols(findings, checked);
            if (ready) {
              findings.addAll(await inspectBookReferences(root, metadata));
              checked.add('Book references');
              final artifacts = SavedArtifactChecks(
                root,
                heldDirectories: {root.path, metadata.path, domainPath},
              );
              findings.addAll(await artifacts.generation());
              checked.add(
                'Generated tree formats in visible Documents folders (source freshness is not recorded)',
              );
              findings.addAll(await artifacts.matches());
              checked.add(
                'Observed bughouse match exports (individual match snapshots)',
              );
            } else {
              skipped.add(
                'Book references and derived artifacts: recovery metadata needs attention first.',
              );
            }
            await _bound(root, metadata);
          },
          (detail) => throw FileSystemException(detail),
        ),
      );
    } on Object {
      findings.add(
        IntegrityFinding(
          IntegrityKind.unavailable,
          documents.path,
          'The profile could not be checked: its roots or lock boundaries are unavailable, changed or overlap.',
        ),
      );
      skipped.add(
        'Checks not completed because the profile was unavailable or changed.',
      );
    }
    return IntegrityReport(
      checkedAt: DateTime.now(),
      findings: findings,
      checked: checked,
      skipped: skipped,
    );
  }

  Future<List<IntegrityFinding>> _settings(Directory metadata) async {
    final path = p.join(metadata.path, 'settings.json');
    try {
      final stagePath = temporaryPathFor(path);
      final stage = await observeFile(stagePath);
      if (stage.status != 1) {
        return [
          IntegrityFinding(
            stage.status == 0
                ? IntegrityKind.unfinished
                : IntegrityKind.unavailable,
            stagePath,
            'An unverified settings publication stage remains. No files were changed.',
          ),
        ];
      }
      final observed = await observeFile(path);
      if (observed.status == 1) return [];
      if (observed.status != 0 || observed.bytes == null) {
        throw const FormatException('Unavailable settings.');
      }
      final text = utf8.decode(observed.bytes!);
      Settings.fromJson(text.startsWith('\ufeff') ? text.substring(1) : text);
      return [];
    } on Object {
      return [
        IntegrityFinding(
          IntegrityKind.unavailable,
          path,
          'Saved settings could not be checked: the file is unavailable or has an unsupported format.',
        ),
      ];
    }
  }

  Future<void> _bound(Directory root, Directory metadata) async {
    if (canonicalRecoveryRoot(documents).path != root.path ||
        canonicalRecoveryRoot(support).path != metadata.path) {
      throw const FileSystemException('The configured profile root changed.');
    }
    final observed = await observeDirectory(root.path);
    if (observed.status != 0)
      throw const FileSystemException('Documents is unavailable or linked.');
    final repertoire = await observeDirectory(p.join(root.path, 'repertoires'));
    if (repertoire.status != 0 && repertoire.status != 1)
      throw const FileSystemException(
        'The repertoire root is unreadable or linked.',
      );
    final own = await observeDirectory(metadata.path);
    if (own.status != 0 && own.status != 1)
      throw const FileSystemException('Support is unreadable or linked.');
  }

  Future<bool> _protocols(
    List<IntegrityFinding> findings,
    List<String> checked,
  ) async {
    // Construction pins roots but performs no recovery. Never call gate.run.
    final gate = RecoveryGate(documents: documents, support: support);
    var ready = true;
    for (final (name, folder, inspect) in [
      ('Training operations', 'training-writes', gate.training.inspect),
      ('Compound edits', 'compound-writes', gate.compounds.inspect),
      (
        'File and folder relocations',
        'relocation-writes',
        gate.relocations.inspect,
      ),
      ('Older relocation notes', 'unfinished-moves', gate.notes.inspect),
    ]) {
      try {
        if (await inspect()) {
          findings.add(
            IntegrityFinding(
              IntegrityKind.unfinished,
              p.join(support.path, folder),
              '$name remain unfinished. Reopen the owning app or retry the accepted operation.',
            ),
          );
          ready = false;
        }
        checked.add(name);
      } on Object {
        findings.add(
          IntegrityFinding(
            IntegrityKind.unavailable,
            p.join(support.path, folder),
            '$name could not be inspected: metadata is unavailable or has an unsupported format.',
          ),
        );
        ready = false;
      }
    }
    try {
      await refuseV1Recovery(documents, support);
      checked.add('Legacy operation compatibility');
    } on Object {
      findings.add(
        IntegrityFinding(
          IntegrityKind.unavailable,
          support.path,
          'Legacy operations need attention: unfinished or unsupported metadata remains. Reopen the legacy app before continuing.',
        ),
      );
      ready = false;
    }
    return ready;
  }
}
