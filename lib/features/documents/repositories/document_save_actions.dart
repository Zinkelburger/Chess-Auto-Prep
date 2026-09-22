import '../models/document_save_state.dart';
import '../models/pgn_document.dart';

/// Save interaction shared by text sessions and structured document editors.
/// A host may serialize its mutable tree only when a command captures a draft.
abstract interface class DocumentSaveActions {
  DocumentSaveState get state;
  Stream<DocumentSaveState> get changes;
  Future<PgnWriteResult?> save();
  Future<PgnWriteResult?> saveCopy(String destination);
  Future<PgnOpenResult> inspectCurrent();
  Future<void> reloadPreservingDraft();
  Future<void> restoreDraft(int index);
  void keepEditing();
}
