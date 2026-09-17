import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../features/generation/models/generation_artifacts.dart';
import '../../features/generation/models/generation_publication.dart';
import '../../features/generation/repositories/generation_artifact_repository.dart';
import '../../services/storage/storage_service.dart';
import 'generation_namespace.dart';
import '../../utils/atomic_file.dart';
import '../../utils/file_text_reader.dart';
import '../../utils/pgn_compression.dart';

class _Run {
  _Run(this.source, this.pointer, this.payloads);
  PgnSnapshot? source;
  PgnSnapshot? pointer;
  Map<GenerationArtifactKind, String> payloads;
  bool selecting = false;
}

class _Proposal {
  _Proposal(this.run, this.pointer, this.payloads, this.manifest);
  final GenerationArtifactRun run;
  final PgnSnapshot? pointer;
  final Map<GenerationArtifactKind, String> payloads;
  final String manifest;
}

/// Immutable payload generations, selected by one atomic revision-checked
/// pointer. A pointer and every payload are validated before any reader adopts
/// them. A failed/uncertain selection never retries or deletes recovery data.
class StorageGenerationArtifactRepository
    implements GenerationArtifactRepository {
  StorageGenerationArtifactRepository({
    required this.storage,
    required this.documents,
    this.nativePaths = true,
    AtomicFileWriter? recoveryWriter,
    Future<void> Function(String)? flushRecoveryDirectory,
  }) : _recoveryWriter = recoveryWriter ?? AtomicFileWriter(),
       _flushRecoveryDirectory = flushRecoveryDirectory ?? syncDirectory;
  final StorageService storage;
  final PgnDocumentStore documents;
  final bool nativePaths;
  final AtomicFileWriter _recoveryWriter;
  final Future<void> Function(String) _flushRecoveryDirectory;
  final _runs = <GenerationArtifactRun, _Run>{};
  final _proposals = <GenerationArtifactProposal, _Proposal>{};

  static String chapterDirectory(String path) =>
      p.join(p.dirname(path), '.cap-generation', p.basename(path));
  static String pointerPath(String path) =>
      p.join(chapterDirectory(path), 'artifacts.current.json');
  static String _id() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
        '${random.nextInt(1 << 32).toRadixString(16)}-'
        '${random.nextInt(1 << 32).toRadixString(16)}';
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static Map<String, String>? _revision(PgnSnapshot? snapshot) =>
      snapshot == null
      ? null
      : {
          'documentId': snapshot.revision.documentId,
          'nativeIdentity': snapshot.revision.nativeIdentity,
          'sha256': snapshot.revision.sha256,
        };
  static bool _matches(dynamic encoded, PgnSnapshot? source) =>
      jsonEncode(encoded) == jsonEncode(_revision(source));

  Future<void> _safeNamespace(String path) async {
    if (!nativePaths) return;
    final chapter = chapterDirectory(path);
    for (final component in [p.dirname(chapter), chapter]) {
      final type = await FileSystemEntity.type(component, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw GenerationArtifactFailure(
          'Artifact namespace collision at $component',
        );
      }
    }
  }

  Future<String> _readPayload(String path) async {
    if (nativePaths &&
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw GenerationArtifactFailure('Artifact is missing or replaced: $path');
    }
    final text = await storage.readFile(path);
    if (text == null) {
      throw GenerationArtifactFailure('Artifact is missing: $path');
    }
    return text;
  }

  Future<PgnSnapshot?> _open(String path) async =>
      switch (await documents.open(path)) {
        PgnOpened(:final snapshot) => snapshot,
        PgnMissing() => null,
        PgnReadFailed(:final error) => throw error,
      };

  @override
  Future<GenerationArtifactSnapshot> read(String path) async {
    try {
      await _safeNamespace(path);
      final pointer = await _open(pointerPath(path));
      if (pointer == null) {
        return GenerationArtifactSnapshot(
          origin: GenerationArtifactOrigin.absent,
        );
      }
      final source = await _open(path);
      final decoded = await _decode(path, pointer, source);
      if ((await _open(path))?.revision != source?.revision ||
          (await _open(pointerPath(path)))?.revision != pointer.revision) {
        throw const GenerationArtifactFailure(
          'The selected generation changed while loading',
        );
      }
      return decoded;
    } catch (error) {
      return GenerationArtifactSnapshot(
        origin: GenerationArtifactOrigin.stale,
        notice: 'Saved analysis was not adopted: $error',
      );
    }
  }

  Future<GenerationArtifactSnapshot> _decode(
    String path,
    PgnSnapshot pointer,
    PgnSnapshot? source,
  ) async {
    final selected = jsonDecode(pointer.content) as Map<String, dynamic>;
    if (selected['version'] != 1 ||
        selected['sourcePath'] != path ||
        !_matches(selected['sourceRevision'], source)) {
      throw const GenerationArtifactFailure('The source chapter has changed');
    }
    final generation = selected['generation'] as String;
    if (p.basename(generation) != generation ||
        !generation.startsWith('artifacts-')) {
      throw const GenerationArtifactFailure('Invalid artifact generation path');
    }
    final directory = p.join(chapterDirectory(path), generation);
    if (nativePaths &&
        await FileSystemEntity.type(directory, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const GenerationArtifactFailure(
        'Artifact generation directory changed',
      );
    }
    final manifest = await _readPayload(p.join(directory, 'manifest.json'));
    if (_hash(manifest) != selected['manifestSha256']) {
      throw const GenerationArtifactFailure('Artifact manifest was edited');
    }
    final data = jsonDecode(manifest) as Map<String, dynamic>;
    if (data['version'] != 1 ||
        data['sourcePath'] != path ||
        data['runId'] != selected['runId']) {
      throw const GenerationArtifactFailure(
        'Artifact manifest identity mismatch',
      );
    }
    final payloads = <GenerationArtifactKind, String>{};
    final entries = data['artifacts'] as Map<String, dynamic>;
    for (final kind in GenerationArtifactKind.values) {
      final expected = entries[kind.name];
      if (expected == null) continue;
      final text = await _readPayload(p.join(directory, '${kind.name}.json'));
      if (_hash(text) != expected) {
        throw GenerationArtifactFailure('The ${kind.name} artifact was edited');
      }
      payloads[kind] = text;
    }
    return GenerationArtifactSnapshot(
      origin: GenerationArtifactOrigin.current,
      payloads: payloads,
      generationId: generation,
    );
  }

  @override
  Future<GenerationArtifactSnapshot> readLegacy(String path) async {
    // These observations never feed begin(): neither naming nor a saved config
    // proves the historical source revision. Keep exact bytes even if malformed.
    final base = p.withoutExtension(path);
    final payloads = <GenerationArtifactKind, String>{};
    final bytes = <GenerationArtifactKind, List<int>>{};
    final failures = <GenerationArtifactKind, GenerationArtifactFailure>{};
    for (final entry in {
      GenerationArtifactKind.tree: '${base}_tree.json',
      GenerationArtifactKind.probes: '${base}_expectimax.json',
      GenerationArtifactKind.traps: '${base}_traps.json',
      GenerationArtifactKind.partial: '${base}_partial_tree.json',
    }.entries) {
      try {
        if (nativePaths) {
          final observed = await observeFile(entry.value);
          if (observed.status == 1) continue;
          if (observed.status != 0 || observed.bytes == null) {
            throw GenerationArtifactFailure(
              'Cannot safely read ${entry.value} (native error ${observed.error})',
            );
          }
          bytes[entry.key] = observed.bytes!;
          final captured = observed.bytes!;
          payloads[entry.key] = await Isolate.run(
            () => decodeTextBytes(maybeGunzip(captured)),
          );
        } else if (await storage.fileExists(entry.value)) {
          final text = await _readPayload(entry.value);
          payloads[entry.key] = text;
          bytes[entry.key] = utf8.encode(text);
        }
      } catch (error) {
        failures[entry.key] = GenerationArtifactFailure(
          error.toString(),
          kind: GenerationArtifactFailureKind.read,
        );
      }
    }
    return GenerationArtifactSnapshot(
      origin: GenerationArtifactOrigin.legacy,
      payloads: payloads,
      originalBytes: bytes,
      readFailures: failures,
      notice: 'Legacy analysis has no recorded source identity. Preview only.',
    );
  }

  @override
  Future<void> exportLegacy(
    GenerationArtifactSnapshot snapshot,
    GenerationArtifactKind kind,
    String destination,
  ) async {
    final bytes = snapshot.originalBytes[kind];
    if (snapshot.origin != GenerationArtifactOrigin.legacy || bytes == null) {
      throw const GenerationArtifactFailure(
        'No captured legacy bytes to export',
      );
    }
    final target = File(destination);
    var installed = false;
    try {
      await _recoveryWriter.transaction(target, (transaction) async {
        await transaction.writeBytes(
          bytes,
          createOnly: true,
          validate: (staged) async {
            final observed = await observeFile(staged.path);
            if (observed.status != 0 ||
                observed.sha256Hex != sha256.convert(bytes).toString()) {
              throw const GenerationArtifactFailure('Export staging changed');
            }
          },
          installNew: (staged, target) async {
            await installNewFile(staged.path, target.path);
            installed = true;
          },
        );
        await _flushRecoveryDirectory(target.parent.path);
      });
    } catch (error) {
      throw GenerationArtifactFailure(
        installed
            ? 'Export may already exist; inspect it before retrying: $error'
            : 'Export failed; an existing destination is never replaced: $error',
        proposalPath: destination,
        kind: installed
            ? GenerationArtifactFailureKind.uncertain
            : error is AtomicNameCollision || error is NativeNameCollision
            ? GenerationArtifactFailureKind.collision
            : GenerationArtifactFailureKind.export,
      );
    }
  }

  @override
  Future<GenerationArtifactRun> begin(
    String path,
    Map<String, dynamic> config, {
    GenerationSource? source,
    String? expectedGenerationId,
  }) async {
    final capturedConfig = GenerationSource.snapshotConfig(config);
    await _safeNamespace(path);
    final captured = source == null ? await _open(path) : source.snapshot;
    if (source != null && source.path != path) {
      throw const GenerationArtifactFailure('Artifact source path mismatch');
    }
    final pointer = await _open(pointerPath(path));
    var payloads = <GenerationArtifactKind, String>{};
    if (pointer != null) {
      try {
        final previous = await _decode(path, pointer, captured);
        if (expectedGenerationId != null &&
            previous.generationId != expectedGenerationId) {
          throw const GenerationArtifactFailure(
            'The saved partial generation changed',
          );
        }
        payloads = previous.payloads;
      } on GenerationArtifactFailure {
        if (expectedGenerationId != null) rethrow;
        // Retained stale generation; a fresh build starts without its caches.
      }
    }
    if (pointer == null && expectedGenerationId != null) {
      throw const GenerationArtifactFailure(
        'The saved partial generation is no longer selected',
      );
    }
    final run = GenerationArtifactRun(
      runId: source?.runId ?? _id(),
      path: path,
      source: captured,
      config: capturedConfig,
    );
    _runs[run] = _Run(captured, pointer, payloads);
    return run;
  }

  @override
  Future<GenerationArtifactProposal> prepare(
    GenerationArtifactRun run,
    Map<GenerationArtifactKind, String?> changes,
  ) async {
    final state = _runs[run];
    if (state == null) {
      throw const GenerationArtifactFailure('Artifact run is closed');
    }
    final expectedPointer = state.pointer;
    final payloads = {...state.payloads};
    for (final entry in changes.entries) {
      if (entry.value == null) {
        payloads.remove(entry.key);
      } else {
        payloads[entry.key] = entry.value!;
      }
    }
    final directory = p.join(chapterDirectory(run.path), 'artifacts-${_id()}');
    final manifestPath = p.join(directory, 'manifest.json');
    final manifest = jsonEncode({
      'version': 1,
      'state': 'proposal',
      'runId': run.runId,
      'sourcePath': run.path,
      'sourceRevision': _revision(state.source),
      'config': run.config,
      'artifacts': {
        for (final entry in payloads.entries)
          entry.key.name: _hash(entry.value),
      },
    });
    try {
      if (nativePaths) await prepareGenerationDirectory(directory);
      await storage.writeFile(manifestPath, manifest, createOnly: true);
      for (final entry in payloads.entries) {
        await storage.writeFile(
          p.join(directory, '${entry.key.name}.json'),
          entry.value,
          createOnly: true,
        );
      }
      if (!identical(_runs[run], state)) {
        throw const GenerationArtifactFailure(
          'Artifact run was closed during staging',
        );
      }
      final proposal = GenerationArtifactProposal(manifestPath);
      _proposals[proposal] = _Proposal(
        run,
        expectedPointer,
        payloads,
        manifest,
      );
      return proposal;
    } catch (error) {
      throw GenerationArtifactFailure(
        'Artifact staging failed: $error',
        proposalPath: manifestPath,
      );
    }
  }

  @override
  Future<void> select(
    GenerationArtifactRun run,
    GenerationArtifactProposal proposal, {
    PgnSnapshot? publishedSource,
  }) async {
    final state = _runs[run];
    final pending = _proposals.remove(proposal);
    void refuse(String reason) => throw GenerationArtifactFailure(
      reason,
      proposalPath: proposal.manifestPath,
    );
    if (state == null ||
        state.selecting ||
        pending == null ||
        !identical(pending.run, run)) {
      refuse('Artifact run no longer owns this proposal');
    }
    final active = state!;
    final prepared = pending!;
    if (prepared.pointer?.revision != active.pointer?.revision) {
      refuse('A newer artifact generation was selected');
    }
    if (publishedSource != null && publishedSource.path != run.path) {
      refuse('Published source path mismatch');
    }
    active.selecting = true;
    try {
      await _safeNamespace(run.path);
      final source = publishedSource ?? active.source;
      final current = await _open(run.path);
      if (current?.revision != source?.revision) {
        refuse('The source chapter changed');
      }
      final text = jsonEncode({
        'version': 1,
        'runId': run.runId,
        'sourcePath': run.path,
        'sourceRevision': _revision(source),
        'generation': p.basename(p.dirname(proposal.manifestPath)),
        'manifestSha256': _hash(prepared.manifest),
      });
      // Revalidate all staged bytes immediately before selecting; edits never
      // become trusted merely because this process originally wrote the file.
      final candidate = PgnSnapshot(
        path: pointerPath(run.path),
        revision:
            current?.revision ??
            const PgnRevision(documentId: '', nativeIdentity: '', sha256: ''),
        content: text,
      );
      await _decode(run.path, candidate, source);
      if (!identical(_runs[run], active)) refuse('Artifact run was closed');
      if ((await _open(run.path))?.revision != source?.revision) {
        refuse('The source chapter changed while validating artifacts');
      }
      final result = active.pointer == null
          ? await documents.create(pointerPath(run.path), text)
          : await documents.save(active.pointer!, text);
      switch (result) {
        case PgnSaved(:final after):
          active.pointer = after;
          active.source = source;
          active.payloads = prepared.payloads;
        case PgnWriteUncertain():
          close(run);
          refuse(
            'Artifact selection outcome is uncertain; reconcile before retrying',
          );
        case PgnConflict():
        case PgnNameCollision():
          close(run);
          refuse('A newer artifact generation was selected');
        case PgnWriteFailed(:final error):
          refuse('Artifact selection failed: $error');
      }
    } finally {
      active.selecting = false;
    }
  }

  @override
  void close(GenerationArtifactRun run) {
    _runs.remove(run);
    _proposals.removeWhere((_, proposal) => identical(proposal.run, run));
  }
}
