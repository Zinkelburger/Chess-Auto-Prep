import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_document_store.dart';

PgnSnapshot snapshot(
  String content, {
  String path = '/main.pgn',
  String revision = '1',
}) => PgnSnapshot(
  path: path,
  content: content,
  revision: PgnRevision(
    documentId: path,
    nativeIdentity: revision,
    sha256: content,
  ),
);

class Store implements PgnDocumentStore {
  @override
  bool get supportsQuarantine => false;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) async => PgnQuarantineFailed(UnsupportedError('Unused in this fixture'));

  PgnSnapshot current = snapshot('original');
  Future<PgnWriteResult> Function(String, String)? onCreate;
  Future<PgnWriteResult> Function(PgnSnapshot, String)? onSave;
  Future<PgnOpenResult> Function(String)? onOpen;
  final saves = <PgnSnapshot>[];
  final creates = <String>[];
  @override
  Future<PgnOpenResult> open(String path) async =>
      onOpen != null ? onOpen!(path) : PgnOpened(current);
  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) async {
    saves.add(baseline);
    if (onSave != null) return onSave!(baseline, content);
    if (baseline.revision != current.revision) return PgnConflict(current);
    current = snapshot(content, revision: '${saves.length + 1}');
    return PgnSaved(before: baseline, after: current);
  }

  @override
  Future<PgnWriteResult> create(String path, String content) async {
    creates.add(path);
    return onCreate != null
        ? onCreate!(path, content)
        : PgnSaved(before: null, after: snapshot(content, path: path));
  }
}
