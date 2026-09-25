import 'package:flutter/widgets.dart';

import '../../documents/controllers/document_close_coordinator.dart';
import '../../documents/widgets/document_close_scope.dart';
import '../controllers/repertoire_controller.dart';

/// Close protection follows the app-owned document, including when its screen
/// has never mounted or has been removed. Failed edits remain close blockers.
class RepertoireCloseHost extends StatelessWidget {
  const RepertoireCloseHost({
    super.key,
    required this.controller,
    required this.child,
  });
  final RepertoireController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => DocumentCloseRegistration(
    revision: () => controller.closeRevision,
    prepare: () async {
      await controller.flushDocumentForClose();
      return DocumentCloseApproval(controller.closeRevision);
    },
    child: child,
  );
}
