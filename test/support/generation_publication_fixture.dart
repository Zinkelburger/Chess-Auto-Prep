import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';

import '../core/fake_storage.dart';
import 'scripted_document_store.dart';

GenerationPublicationController generationPublicationFixture() =>
    GenerationPublicationController(
      documents: Store(),
      drafts: StorageGenerationDraftRepository(
        MemoryStorage(),
        prepareDirectory: (_) async {},
      ),
    );
