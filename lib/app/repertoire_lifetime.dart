import 'dart:async';

import '../features/repertoires/controllers/repertoire_controller.dart';
import '../features/repertoires/repositories/repertoire_decoder.dart';
import '../features/repertoires/repositories/repertoire_document_repository.dart';

/// The Builder's document survives screen removal. Trainer sessions remain
/// independent so a training cursor cannot replace the editable workspace.
class RepertoireLifetime {
  RepertoireLifetime({
    required RepertoireDocumentRepository documents,
    required RepertoireDecoder decoder,
  }) : controller = RepertoireController(
         documents: documents,
         decoder: decoder,
       );

  final RepertoireController controller;
  Future<void>? _shutdown;

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    try {
      await controller.flushDocumentForClose();
    } finally {
      controller.dispose();
    }
  }

  void dispose() => unawaited(shutdown().catchError((Object _) {}));
}
